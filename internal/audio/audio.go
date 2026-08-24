package audio

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	BatchSize                 = 6
	ModelName                 = "cohere-transcribe-03-2026-Q4_K_M"
	targetChunkSeconds        = 30
	minimumChunkSeconds       = 15
	maximumChunkSeconds       = 36
	boundarySearchSeconds     = 6
	maximumAudioSeconds       = 10 * 60
	maximumDecodedWAVBytes    = maximumAudioSeconds*16_000*2 + 1024*1024
	conversionTimeout         = 120 * time.Second
	conversionMaximumLogBytes = 16 * 1024 * 1024
)

var pcmSubformatGUID = []byte{0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}

var extensions = map[string]string{
	"audio/aac":    "aac",
	"audio/flac":   "flac",
	"audio/mp4":    "m4a",
	"audio/mpeg":   "mp3",
	"audio/ogg":    "ogg",
	"audio/opus":   "opus",
	"audio/wav":    "wav",
	"audio/webm":   "webm",
	"audio/x-caf":  "caf",
	"audio/x-flac": "flac",
	"audio/x-m4a":  "m4a",
}

type PCM16WAV struct {
	PCM         []byte
	SampleCount int
	SampleRate  int
}

func ParsePCM16WAV(wav []byte) (PCM16WAV, error) {
	if len(wav) < 12 || string(wav[:4]) != "RIFF" {
		return PCM16WAV{}, errors.New("decoded audio was not a RIFF WAV file")
	}
	if string(wav[8:12]) != "WAVE" {
		return PCM16WAV{}, errors.New("decoded audio was not a WAVE file")
	}

	var format []byte
	var pcm []byte
	for offset := 12; offset+8 <= len(wav); {
		id := string(wav[offset : offset+4])
		size := int(binary.LittleEndian.Uint32(wav[offset+4 : offset+8]))
		contentsStart := offset + 8
		contentsEnd := contentsStart + size
		if contentsEnd < contentsStart || contentsEnd > len(wav) {
			return PCM16WAV{}, fmt.Errorf("decoded WAV contained a truncated %s chunk", id)
		}
		if id == "fmt " {
			format = wav[contentsStart:contentsEnd]
		}
		if id == "data" {
			pcm = wav[contentsStart:contentsEnd]
		}
		offset = contentsEnd + (size & 1)
	}

	if len(format) < 16 {
		return PCM16WAV{}, errors.New("decoded WAV contained no valid fmt chunk")
	}
	if pcm == nil {
		return PCM16WAV{}, errors.New("decoded WAV contained no data chunk")
	}
	audioFormat := binary.LittleEndian.Uint16(format[0:2])
	channels := binary.LittleEndian.Uint16(format[2:4])
	sampleRate := binary.LittleEndian.Uint32(format[4:8])
	blockAlign := binary.LittleEndian.Uint16(format[12:14])
	bitsPerSample := binary.LittleEndian.Uint16(format[14:16])
	pcmFormat := audioFormat == 1 || (audioFormat == 0xfffe &&
		len(format) >= 40 &&
		binary.LittleEndian.Uint16(format[16:18]) >= 22 &&
		binary.LittleEndian.Uint16(format[18:20]) == 16 &&
		bytes.Equal(format[24:40], pcmSubformatGUID))
	if !pcmFormat || channels != 1 || sampleRate != 16_000 || blockAlign != 2 || bitsPerSample != 16 {
		return PCM16WAV{}, errors.New("decoded WAV was not mono 16 kHz 16-bit PCM")
	}
	if len(pcm) == 0 {
		return PCM16WAV{}, errors.New("decoded WAV contained no audio samples")
	}
	if len(pcm)%int(blockAlign) != 0 {
		return PCM16WAV{}, errors.New("decoded WAV ended with a partial sample")
	}
	return PCM16WAV{PCM: pcm, SampleCount: len(pcm) / int(blockAlign), SampleRate: int(sampleRate)}, nil
}

func QuietChunkBoundaries(wav PCM16WAV) []int {
	durationSeconds := float64(wav.SampleCount) / float64(wav.SampleRate)
	chunkCount := max(1, int(durationSeconds/targetChunkSeconds+0.5), (wav.SampleCount+maximumChunkSeconds*wav.SampleRate-1)/(maximumChunkSeconds*wav.SampleRate))
	if chunkCount == 1 {
		return []int{0, wav.SampleCount}
	}

	frameSamples := max(1, wav.SampleRate/100)
	frameCount := (wav.SampleCount + frameSamples - 1) / frameSamples
	energy := make([]float64, frameCount+1)
	for frame := range frameCount {
		start := frame * frameSamples
		end := min(wav.SampleCount, start+frameSamples)
		var sum float64
		for sample := start; sample < end; sample++ {
			amplitude := int16(binary.LittleEndian.Uint16(wav.PCM[sample*2 : sample*2+2]))
			sum += float64(amplitude) * float64(amplitude)
		}
		energy[frame+1] = energy[frame] + sum/float64(end-start)
	}

	boundaries := []int{0}
	start := 0
	for chunksRemaining := chunkCount; chunksRemaining > 1; chunksRemaining-- {
		target := start + (wav.SampleCount-start+chunksRemaining/2)/chunksRemaining
		lower := max(
			start+minimumChunkSeconds*wav.SampleRate,
			wav.SampleCount-(chunksRemaining-1)*maximumChunkSeconds*wav.SampleRate,
			target-boundarySearchSeconds*wav.SampleRate,
		)
		upper := min(
			start+maximumChunkSeconds*wav.SampleRate,
			wav.SampleCount-(chunksRemaining-1)*minimumChunkSeconds*wav.SampleRate,
			target+boundarySearchSeconds*wav.SampleRate,
		)
		lowerFrame := (lower + frameSamples - 1) / frameSamples
		upperFrame := upper / frameSamples
		const halfWindowFrames = 5
		bestFrame := lowerFrame
		bestEnergy := float64(^uint64(0))
		bestDistance := int(^uint(0) >> 1)
		for frame := lowerFrame; frame <= upperFrame; frame++ {
			windowStart := max(0, frame-halfWindowFrames)
			windowEnd := min(frameCount, frame+halfWindowFrames)
			candidateEnergy := (energy[windowEnd] - energy[windowStart]) / float64(windowEnd-windowStart)
			distance := abs(frame*frameSamples - target)
			if candidateEnergy < bestEnergy || candidateEnergy == bestEnergy && distance < bestDistance {
				bestFrame = frame
				bestEnergy = candidateEnergy
				bestDistance = distance
			}
		}
		start = bestFrame * frameSamples
		boundaries = append(boundaries, start)
	}
	return append(boundaries, wav.SampleCount)
}

func Float32Chunks(wav PCM16WAV, boundaries []int) [][]float32 {
	chunks := make([][]float32, 0, len(boundaries)-1)
	for index := 0; index+1 < len(boundaries); index++ {
		start := boundaries[index]
		end := boundaries[index+1]
		chunk := make([]float32, end-start)
		for sample := start; sample < end; sample++ {
			amplitude := int16(binary.LittleEndian.Uint16(wav.PCM[sample*2 : sample*2+2]))
			chunk[sample-start] = float32(amplitude) / 32_768
		}
		chunks = append(chunks, chunk)
	}
	return chunks
}

func Decode(ctx context.Context, contents []byte, mimeType, filename, converterPath string) (PCM16WAV, error) {
	if len(contents) == 0 {
		return PCM16WAV{}, errors.New("audio upload was empty")
	}
	normalizedMimeType := strings.ToLower(strings.TrimSpace(strings.SplitN(mimeType, ";", 2)[0]))
	extension := extensions[normalizedMimeType]
	if extension == "" {
		return PCM16WAV{}, fmt.Errorf("%s has an unsupported audio format", filename)
	}
	if !filepath.IsAbs(converterPath) {
		return PCM16WAV{}, errors.New("AFCONVERT_PATH must be an absolute path")
	}
	converter, err := os.Stat(converterPath)
	if err != nil || !converter.Mode().IsRegular() || converter.Mode().Perm()&0o111 == 0 {
		return PCM16WAV{}, fmt.Errorf("the macOS afconvert audio converter is unavailable at %q; check AFCONVERT_PATH", converterPath)
	}

	directory, err := os.MkdirTemp("", "chinwag-decode-")
	if err != nil {
		return PCM16WAV{}, fmt.Errorf("create audio conversion directory: %w", err)
	}
	defer os.RemoveAll(directory)
	if err := os.Chmod(directory, 0o700); err != nil {
		return PCM16WAV{}, fmt.Errorf("secure audio conversion directory: %w", err)
	}
	inputPath := filepath.Join(directory, "input."+extension)
	decodedPath := filepath.Join(directory, "decoded.wav")
	if err := os.WriteFile(inputPath, contents, 0o600); err != nil {
		return PCM16WAV{}, fmt.Errorf("write temporary audio: %w", err)
	}

	conversionContext, cancel := context.WithTimeout(ctx, conversionTimeout)
	defer cancel()
	command := exec.CommandContext(conversionContext, converterPath, inputPath, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", decodedPath)
	var output limitedBuffer
	output.limit = conversionMaximumLogBytes
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		if contextError := conversionContext.Err(); contextError != nil {
			return PCM16WAV{}, contextError
		}
		detail := strings.TrimSpace(output.String())
		if detail == "" {
			detail = err.Error()
		}
		if len(detail) > 2_000 {
			detail = detail[len(detail)-2_000:]
		}
		return PCM16WAV{}, fmt.Errorf("audio conversion failed: %s", detail)
	}

	metadata, err := os.Stat(decodedPath)
	if err != nil {
		return PCM16WAV{}, fmt.Errorf("audio conversion produced no WAV: %w", err)
	}
	if metadata.Size() > maximumDecodedWAVBytes {
		return PCM16WAV{}, errors.New("audio recording exceeds the 10 minute local transcription limit")
	}
	decoded, err := os.ReadFile(decodedPath)
	if err != nil {
		return PCM16WAV{}, fmt.Errorf("read converted audio: %w", err)
	}
	wav, err := ParsePCM16WAV(decoded)
	if err != nil {
		return PCM16WAV{}, fmt.Errorf("audio conversion produced invalid PCM WAV: %w", err)
	}
	if wav.SampleCount > maximumAudioSeconds*wav.SampleRate {
		return PCM16WAV{}, errors.New("audio recording exceeds the 10 minute local transcription limit")
	}
	return wav, nil
}

type limitedBuffer struct {
	bytes.Buffer
	limit int
}

func (buffer *limitedBuffer) Write(contents []byte) (int, error) {
	remaining := buffer.limit - buffer.Len()
	if remaining <= 0 {
		return 0, io.ErrShortWrite
	}
	if len(contents) > remaining {
		written, _ := buffer.Buffer.Write(contents[:remaining])
		return written, io.ErrShortWrite
	}
	return buffer.Buffer.Write(contents)
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}
