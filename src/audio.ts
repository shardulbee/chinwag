import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { access, chmod, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";

const TARGET_CHUNK_SECONDS = 30;
const MIN_CHUNK_SECONDS = 15;
const MAX_CHUNK_SECONDS = 36;
const BOUNDARY_SEARCH_SECONDS = 6;
export const TRANSCRIPTION_BATCH_SIZE = 6;
export const TRANSCRIPTION_MODEL_NAME = "cohere-transcribe-03-2026-Q4_K_M";
const MAX_AUDIO_SECONDS = 10 * 60;
const MAX_DECODED_WAV_BYTES = MAX_AUDIO_SECONDS * 16_000 * 2 + 1024 * 1024;
const PROCESS_TIMEOUT_MS = 120_000;
const PROCESS_MAX_BUFFER = 16 * 1024 * 1024;
const PCM_SUBFORMAT_GUID = Buffer.from("0100000000001000800000aa00389b71", "hex");

const audioExtensions: Readonly<Record<string, string>> = {
  "audio/aac": "aac",
  "audio/flac": "flac",
  "audio/mp4": "m4a",
  "audio/mpeg": "mp3",
  "audio/ogg": "ogg",
  "audio/opus": "opus",
  "audio/wav": "wav",
  "audio/webm": "webm",
  "audio/x-caf": "caf",
  "audio/x-flac": "flac",
  "audio/x-m4a": "m4a",
};

export interface Pcm16Wav {
  pcm: Buffer;
  sampleCount: number;
  sampleRate: number;
}

export function parsePcm16Wav(bytes: Uint8Array): Pcm16Wav {
  const wav = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (wav.length < 12 || wav.toString("ascii", 0, 4) !== "RIFF") {
    throw new Error("decoded audio was not a RIFF WAV file");
  }
  if (wav.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error("decoded audio was not a WAVE file");
  }

  let format: Buffer | undefined;
  let pcm: Buffer | undefined;
  let offset = 12;
  while (offset + 8 <= wav.length) {
    const id = wav.toString("ascii", offset, offset + 4);
    const size = wav.readUInt32LE(offset + 4);
    const contentsStart = offset + 8;
    const contentsEnd = contentsStart + size;
    if (contentsEnd > wav.length) throw new Error(`decoded WAV contained a truncated ${id} chunk`);
    if (id === "fmt ") format = wav.subarray(contentsStart, contentsEnd);
    if (id === "data") pcm = wav.subarray(contentsStart, contentsEnd);
    offset = contentsEnd + (size & 1);
  }

  if (!format || format.length < 16) throw new Error("decoded WAV contained no valid fmt chunk");
  if (!pcm) throw new Error("decoded WAV contained no data chunk");
  const audioFormat = format.readUInt16LE(0);
  const channels = format.readUInt16LE(2);
  const sampleRate = format.readUInt32LE(4);
  const blockAlign = format.readUInt16LE(12);
  const bitsPerSample = format.readUInt16LE(14);
  const pcmFormat =
    audioFormat === 1 ||
    (audioFormat === 0xfffe &&
      format.length >= 40 &&
      format.readUInt16LE(16) >= 22 &&
      format.readUInt16LE(18) === 16 &&
      format.subarray(24, 40).equals(PCM_SUBFORMAT_GUID));
  if (
    !pcmFormat ||
    channels !== 1 ||
    sampleRate !== 16_000 ||
    blockAlign !== 2 ||
    bitsPerSample !== 16
  ) {
    throw new Error("decoded WAV was not mono 16 kHz 16-bit PCM");
  }
  if (pcm.length === 0) throw new Error("decoded WAV contained no audio samples");
  if (pcm.length % blockAlign !== 0) throw new Error("decoded WAV ended with a partial sample");
  return { pcm, sampleCount: pcm.length / blockAlign, sampleRate };
}

export function findQuietChunkBoundaries(wav: Pcm16Wav): number[] {
  const { pcm, sampleCount, sampleRate } = wav;
  const durationSeconds = sampleCount / sampleRate;
  const chunkCount = Math.max(
    1,
    Math.round(durationSeconds / TARGET_CHUNK_SECONDS),
    Math.ceil(durationSeconds / MAX_CHUNK_SECONDS),
  );
  if (chunkCount === 1) return [0, sampleCount];

  const frameSamples = Math.max(1, Math.round(sampleRate / 100));
  const frameCount = Math.ceil(sampleCount / frameSamples);
  const energy = new Float64Array(frameCount + 1);
  for (let frame = 0; frame < frameCount; frame++) {
    const start = frame * frameSamples;
    const end = Math.min(sampleCount, start + frameSamples);
    let sum = 0;
    for (let sample = start; sample < end; sample++) {
      const amplitude = pcm.readInt16LE(sample * 2);
      sum += amplitude * amplitude;
    }
    energy[frame + 1] = energy[frame]! + sum / (end - start);
  }

  const boundaries = [0];
  let start = 0;
  for (let chunksRemaining = chunkCount; chunksRemaining > 1; chunksRemaining--) {
    const target = start + Math.round((sampleCount - start) / chunksRemaining);
    const lower = Math.max(
      start + MIN_CHUNK_SECONDS * sampleRate,
      sampleCount - (chunksRemaining - 1) * MAX_CHUNK_SECONDS * sampleRate,
      target - BOUNDARY_SEARCH_SECONDS * sampleRate,
    );
    const upper = Math.min(
      start + MAX_CHUNK_SECONDS * sampleRate,
      sampleCount - (chunksRemaining - 1) * MIN_CHUNK_SECONDS * sampleRate,
      target + BOUNDARY_SEARCH_SECONDS * sampleRate,
    );
    const lowerFrame = Math.ceil(lower / frameSamples);
    const upperFrame = Math.floor(upper / frameSamples);
    const halfWindowFrames = 5;
    let bestFrame = lowerFrame;
    let bestEnergy = Number.POSITIVE_INFINITY;
    let bestDistance = Number.POSITIVE_INFINITY;
    for (let frame = lowerFrame; frame <= upperFrame; frame++) {
      const windowStart = Math.max(0, frame - halfWindowFrames);
      const windowEnd = Math.min(frameCount, frame + halfWindowFrames);
      const candidateEnergy =
        (energy[windowEnd]! - energy[windowStart]!) / (windowEnd - windowStart);
      const distance = Math.abs(frame * frameSamples - target);
      if (
        candidateEnergy < bestEnergy ||
        (candidateEnergy === bestEnergy && distance < bestDistance)
      ) {
        bestFrame = frame;
        bestEnergy = candidateEnergy;
        bestDistance = distance;
      }
    }
    start = bestFrame * frameSamples;
    boundaries.push(start);
  }
  boundaries.push(sampleCount);
  return boundaries;
}

function run(
  command: string,
  arguments_: readonly string[],
  signal?: AbortSignal,
): Promise<{ stderr: string; stdout: string }> {
  return new Promise((resolveRun, rejectRun) => {
    execFile(
      command,
      arguments_,
      {
        encoding: "utf8",
        maxBuffer: PROCESS_MAX_BUFFER,
        timeout: PROCESS_TIMEOUT_MS,
        ...(signal ? { signal } : {}),
      },
      (error, stdout, stderr) => {
        if (error) {
          Object.assign(error, { stderr, stdout });
          rejectRun(error);
        } else {
          resolveRun({ stderr, stdout });
        }
      },
    );
  });
}

function failureDetail(error: unknown): string {
  if (error && typeof error === "object") {
    const value = error as { message?: unknown; stderr?: unknown };
    if (typeof value.stderr === "string" && value.stderr.trim()) {
      return value.stderr.trim().slice(-2_000);
    }
    if (typeof value.message === "string" && value.message.trim()) return value.message.trim();
  }
  return String(error);
}

async function requireFile(
  path: string,
  setting: string,
  description: string,
  mode: number,
): Promise<void> {
  if (!isAbsolute(path)) throw new Error(`${setting} must be an absolute path`);
  try {
    const metadata = await stat(path);
    if (!metadata.isFile()) throw new Error("not a file");
    await access(path, mode);
  } catch {
    throw new Error(`${description} is unavailable at ${JSON.stringify(path)}; check ${setting}`);
  }
}

export async function decodeAudioToPcm(
  audio: Uint8Array,
  mimeType: string,
  filename: string,
  converterPath: string,
  signal?: AbortSignal,
): Promise<Pcm16Wav> {
  signal?.throwIfAborted();
  if (audio.byteLength === 0) throw new Error("audio upload was empty");
  const normalizedMimeType = mimeType.split(";", 1)[0]!.trim().toLowerCase();
  const extension = audioExtensions[normalizedMimeType];
  if (!extension) throw new Error(`${filename} has an unsupported audio format`);
  await requireFile(
    converterPath,
    "AFCONVERT_PATH",
    "the macOS afconvert audio converter",
    constants.X_OK,
  );

  let directory: string | undefined;
  try {
    directory = await mkdtemp(join(tmpdir(), "sharpi-transcribe-decode-"));
    await chmod(directory, 0o700);
    const inputPath = join(directory, `input.${extension}`);
    const decodedPath = join(directory, "decoded.wav");
    await writeFile(inputPath, audio, { mode: 0o600 });
    try {
      await run(
        converterPath,
        [inputPath, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", decodedPath],
        signal,
      );
    } catch (error) {
      throw new Error(`audio conversion failed: ${failureDetail(error)}`);
    }

    try {
      signal?.throwIfAborted();
      const decoded = await stat(decodedPath);
      if (decoded.size > MAX_DECODED_WAV_BYTES) {
        throw new Error("audio recording exceeds the 10 minute local transcription limit");
      }
      const wav = parsePcm16Wav(await readFile(decodedPath));
      if (wav.sampleCount > MAX_AUDIO_SECONDS * wav.sampleRate) {
        throw new Error("audio recording exceeds the 10 minute local transcription limit");
      }
      return wav;
    } catch (error) {
      throw new Error(`audio conversion produced invalid PCM WAV: ${failureDetail(error)}`);
    }
  } finally {
    if (directory) await rm(directory, { force: true, maxRetries: 3, recursive: true });
  }
}
