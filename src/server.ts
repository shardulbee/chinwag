import { constants } from "node:fs";
import { access, stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { extname } from "node:path";
import { TranscribeModel, type TranscribeOptions } from "transcribe-cpp";
import {
  decodeAudioToPcm,
  findQuietChunkBoundaries,
  TRANSCRIPTION_BATCH_SIZE,
  TRANSCRIPTION_MODEL_NAME,
  type Pcm16Wav,
} from "./audio.ts";

const HOST = "127.0.0.1";
const DEFAULT_PORT = 3212;
const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
const REQUEST_OVERHEAD_BYTES = 1_000_000;
const TRANSCRIPTION_TIMEOUT_MS = 120_000;
const MAX_QUEUED_REQUESTS = 3;
const MODEL_DISPLAY_NAME = "Cohere Transcribe 03-2026 · Q4";

const mimeTypesByExtension: Readonly<Record<string, string>> = {
  ".aac": "audio/aac",
  ".caf": "audio/x-caf",
  ".flac": "audio/flac",
  ".m4a": "audio/mp4",
  ".mp3": "audio/mpeg",
  ".mp4": "audio/mp4",
  ".mpeg": "audio/mpeg",
  ".mpga": "audio/mpeg",
  ".oga": "audio/ogg",
  ".ogg": "audio/ogg",
  ".opus": "audio/opus",
  ".wav": "audio/wav",
  ".webm": "audio/webm",
};
const supportedMimeTypes = new Set([
  ...Object.values(mimeTypesByExtension),
  "audio/x-flac",
  "audio/x-m4a",
]);

class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type EngineState = "error" | "loading" | "ready" | "transcribing";

interface LastTranscription {
  audioSeconds: number;
  completedAt: string;
  elapsedMs: number;
}

interface EngineStatus {
  backend: string;
  device: string;
  error: string | undefined;
  lastTranscription: LastTranscription | undefined;
  queuedRequests: number;
  state: EngineState;
}

const status: EngineStatus = {
  backend: "Metal",
  device: "Apple GPU",
  error: undefined,
  lastTranscription: undefined,
  queuedRequests: 0,
  state: "loading",
};

let model: TranscribeModel | undefined;
let serialTail: Promise<void> = Promise.resolve();

function log(
  level: "error" | "info",
  event: string,
  fields: Readonly<Record<string, unknown>> = {},
): void {
  const line = JSON.stringify({
    ...fields,
    v: 1,
    ts: new Date().toISOString(),
    level,
    event,
    service: "sharpi-transcribe",
    pid: process.pid,
  });
  if (level === "error") console.error(line);
  else console.log(line);
}

function servicePort(environment: NodeJS.ProcessEnv = process.env): number {
  const raw = environment.TRANSCRIPTION_PORT?.trim();
  if (!raw) return DEFAULT_PORT;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("TRANSCRIPTION_PORT must be an integer from 1 to 65535");
  }
  return port;
}

function requiredPath(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`set ${name} before starting the transcription service`);
  return value;
}

function writeJson(response: ServerResponse, responseStatus: number, value: unknown): void {
  const bytes = Buffer.from(`${JSON.stringify(value)}\n`);
  response.writeHead(responseStatus, {
    "cache-control": "private, no-store",
    "content-length": bytes.length,
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "content-type": "application/json; charset=utf-8",
    "x-content-type-options": "nosniff",
  });
  response.end(bytes);
}

function writeText(response: ServerResponse, responseStatus: number, text: string): void {
  const bytes = Buffer.from(`${text}\n`);
  response.writeHead(responseStatus, {
    "cache-control": "private, no-store",
    "content-length": bytes.length,
    "content-type": "text/plain; charset=utf-8",
    "x-content-type-options": "nosniff",
  });
  response.end(bytes);
}

function writeError(response: ServerResponse, error: unknown): void {
  const statusCode = error instanceof HttpError ? error.status : 500;
  const message = error instanceof Error ? error.message : "transcription failed";
  writeJson(response, statusCode, {
    error: {
      message,
      type: statusCode >= 500 ? "server_error" : "invalid_request_error",
    },
  });
}

async function requestBytes(request: IncomingMessage, limit: number): Promise<Buffer> {
  const declared = Number(request.headers["content-length"]);
  if (Number.isFinite(declared) && declared > limit) {
    throw new HttpError(413, "request body is too large");
  }
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += bytes.length;
    if (length > limit) throw new HttpError(413, "request body is too large");
    chunks.push(bytes);
  }
  return Buffer.concat(chunks);
}

async function multipart(request: IncomingMessage): Promise<FormData> {
  const contentType = request.headers["content-type"];
  if (!contentType?.toLowerCase().startsWith("multipart/form-data;")) {
    throw new HttpError(415, "request body must be multipart form data");
  }
  try {
    const bytes = await requestBytes(request, MAX_UPLOAD_BYTES + REQUEST_OVERHEAD_BYTES);
    return await new Response(new Uint8Array(bytes), {
      headers: { "content-type": contentType },
    }).formData();
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "request body is not valid multipart form data");
  }
}

function oneTextField(form: FormData, name: string): string | undefined {
  const fields = form.getAll(name);
  if (fields.length === 0) return undefined;
  if (fields.length !== 1 || typeof fields[0] !== "string") {
    throw new HttpError(400, `${name} must appear at most once and contain text`);
  }
  return fields[0].trim() || undefined;
}

function pcmFloat32(wav: Pcm16Wav, start: number, end: number): Float32Array {
  const result = new Float32Array(end - start);
  for (let index = start; index < end; index++) {
    result[index - start] = wav.pcm.readInt16LE(index * 2) / 32_768;
  }
  return result;
}

function runSerial<T>(work: () => Promise<T>): Promise<T> {
  const result = serialTail.then(work, work);
  serialTail = result.then(
    () => undefined,
    () => undefined,
  );
  return result;
}

async function transcribeUpload(
  bytes: Uint8Array,
  mimeType: string,
  filename: string,
  language: string | undefined,
  signal: AbortSignal,
): Promise<{ audioSeconds: number; text: string }> {
  const activeModel = model;
  if (!activeModel || status.state === "loading" || status.state === "error") {
    throw new HttpError(503, status.error ?? "the transcription model is still loading");
  }
  if (status.queuedRequests >= MAX_QUEUED_REQUESTS) {
    throw new HttpError(429, "the transcription service queue is full");
  }
  if (signal.aborted) throw new HttpError(408, "transcription was cancelled");

  status.queuedRequests += 1;
  return runSerial(async () => {
    status.queuedRequests -= 1;
    if (signal.aborted) throw new HttpError(408, "transcription was cancelled");
    status.state = "transcribing";
    status.error = undefined;
    const startedAt = performance.now();
    try {
      const wav = await decodeAudioToPcm(
        bytes,
        mimeType,
        filename,
        process.env.AFCONVERT_PATH?.trim() || "/usr/bin/afconvert",
        signal,
      );
      signal.throwIfAborted();
      const boundaries = findQuietChunkBoundaries(wav);
      const chunks: Float32Array[] = [];
      for (let index = 0; index < boundaries.length - 1; index++) {
        chunks.push(pcmFloat32(wav, boundaries[index]!, boundaries[index + 1]!));
      }

      const options: TranscribeOptions = { signal, timestamps: "none" };
      if (language) options.language = language;
      const transcriptParts: string[] = [];
      const session = activeModel.createSession();
      try {
        for (let offset = 0; offset < chunks.length; offset += TRANSCRIPTION_BATCH_SIZE) {
          const results = await session.runBatch(
            chunks.slice(offset, offset + TRANSCRIPTION_BATCH_SIZE),
            options,
          );
          for (const item of results) {
            if (!item.ok) throw item.error;
            const text = item.result.text.trim();
            if (text) transcriptParts.push(text);
          }
        }
      } finally {
        session.dispose();
      }

      const text = transcriptParts.join(" ").trim();
      if (!text) throw new Error("Cohere returned an empty transcription");
      const audioSeconds = wav.sampleCount / wav.sampleRate;
      const elapsedMs = Math.round(performance.now() - startedAt);
      status.lastTranscription = {
        audioSeconds: Math.round(audioSeconds * 10) / 10,
        completedAt: new Date().toISOString(),
        elapsedMs,
      };
      log("info", "transcription.completed", {
        audioSeconds: status.lastTranscription.audioSeconds,
        elapsedMs,
      });
      return { audioSeconds, text };
    } catch (error) {
      if (signal.aborted) throw new HttpError(408, "transcription was cancelled");
      throw error;
    } finally {
      status.state = "ready";
    }
  });
}

async function handleTranscription(
  request: IncomingMessage,
  response: ServerResponse,
): Promise<void> {
  const form = await multipart(request);
  const allowedFields = new Set([
    "file",
    "language",
    "model",
    "prompt",
    "response_format",
    "temperature",
    "timestamp_granularities[]",
  ]);
  for (const name of new Set(form.keys())) {
    if (!allowedFields.has(name)) throw new HttpError(400, `unknown multipart field: ${name}`);
  }

  const files = form.getAll("file");
  const file = files[0];
  if (files.length !== 1 || typeof file === "string" || !file) {
    throw new HttpError(400, "file must contain exactly one audio upload");
  }
  if (file.size === 0) throw new HttpError(400, "audio upload was empty");
  if (file.size > MAX_UPLOAD_BYTES) throw new HttpError(413, "audio upload is too large");

  const responseFormat = oneTextField(form, "response_format") ?? "json";
  if (!new Set(["json", "text", "verbose_json"]).has(responseFormat)) {
    throw new HttpError(400, "response_format must be json, text, or verbose_json");
  }
  const language = oneTextField(form, "language");
  const extension = extname(file.name).toLowerCase();
  const uploadedMimeType = file.type.toLowerCase();
  const mimeType = supportedMimeTypes.has(uploadedMimeType)
    ? uploadedMimeType
    : mimeTypesByExtension[extension];
  if (!mimeType)
    throw new HttpError(400, `${file.name || "audio"} has an unsupported audio format`);

  const abort = new AbortController();
  const timeout = setTimeout(() => abort.abort(), TRANSCRIPTION_TIMEOUT_MS);
  request.once("aborted", () => abort.abort());
  response.once("close", () => {
    if (!response.writableEnded) abort.abort();
  });
  try {
    const result = await transcribeUpload(
      new Uint8Array(await file.arrayBuffer()),
      mimeType,
      file.name || `audio${extension}`,
      language,
      abort.signal,
    );
    if (responseFormat === "text") {
      writeText(response, 200, result.text);
    } else if (responseFormat === "verbose_json") {
      writeJson(response, 200, {
        duration: Math.round(result.audioSeconds * 1_000) / 1_000,
        language: language ?? "",
        text: result.text,
      });
    } else {
      writeJson(response, 200, { text: result.text });
    }
  } finally {
    clearTimeout(timeout);
  }
}

function health(): Record<string, unknown> {
  return {
    backend: status.backend,
    device: status.device,
    error: status.error ?? null,
    lastTranscription: status.lastTranscription ?? null,
    model: TRANSCRIPTION_MODEL_NAME,
    modelDisplayName: MODEL_DISPLAY_NAME,
    pid: process.pid,
    queuedRequests: status.queuedRequests,
    state: status.state,
  };
}

async function loadModel(): Promise<void> {
  try {
    const modelPath = requiredPath("TRANSCRIBE_MODEL");
    const metadata = await stat(modelPath);
    if (!metadata.isFile()) throw new Error("TRANSCRIBE_MODEL does not name a file");
    await access(modelPath, constants.R_OK);
    const loaded = await TranscribeModel.load(modelPath, { backend: "metal" });
    model = loaded;
    status.backend = "Metal";
    status.device = loaded.device.description || loaded.device.name || "Apple GPU";
    status.state = "ready";
    status.error = undefined;
    log("info", "transcription.ready", {
      backend: status.backend,
      device: status.device,
      model: TRANSCRIPTION_MODEL_NAME,
    });
  } catch (error) {
    status.state = "error";
    status.error = error instanceof Error ? error.message : String(error);
    log("error", "transcription.unavailable", { error: status.error });
  }
}

const port = servicePort();
const server = createServer((request, response) => {
  void (async () => {
    const method = request.method ?? "GET";
    const url = new URL(request.url ?? "/", `http://${HOST}:${port}`);
    if (method === "GET" && url.pathname === "/healthz") {
      writeJson(response, 200, health());
      return;
    }
    if (method === "POST" && url.pathname === "/v1/audio/transcriptions") {
      await handleTranscription(request, response);
      return;
    }
    writeJson(response, 404, { error: { message: "not found", type: "invalid_request_error" } });
  })().catch((error: unknown) => {
    if (response.destroyed) return;
    if (!response.headersSent) writeError(response, error);
    else response.destroy();
    if (!(error instanceof HttpError) && !(error instanceof Error && error.name === "AbortError")) {
      log("error", "transcription.failed", {
        error: error instanceof Error ? error.message : String(error),
      });
    }
  });
});
server.requestTimeout = TRANSCRIPTION_TIMEOUT_MS + 10_000;
server.headersTimeout = 30_000;
server.on("error", (error) => {
  log("error", "transcription.listener.failed", { error: error.message });
  process.exitCode = 1;
});
server.listen(port, HOST, () => {
  log("info", "transcription.listening", { host: HOST, port });
  void loadModel();
});

function shutdown(): void {
  server.close(() => {
    model?.dispose();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 5_000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
