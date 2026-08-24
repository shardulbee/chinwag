package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/shardulbee/chinwag/internal/audio"
	"github.com/shardulbee/chinwag/internal/transcribe"
)

const (
	host                     = "127.0.0.1"
	defaultPort              = 3212
	maximumUploadBytes       = 25 * 1024 * 1024
	requestOverheadBytes     = 1_000_000
	transcriptionTimeout     = 120 * time.Second
	maximumQueuedRequests    = 3
	modelDisplayName         = "Cohere Transcribe 03-2026 · Q4"
	maximumMultipartFieldLen = 64 * 1024
)

var mimeTypesByExtension = map[string]string{
	".aac":  "audio/aac",
	".caf":  "audio/x-caf",
	".flac": "audio/flac",
	".m4a":  "audio/mp4",
	".mp3":  "audio/mpeg",
	".mp4":  "audio/mp4",
	".mpeg": "audio/mpeg",
	".mpga": "audio/mpeg",
	".oga":  "audio/ogg",
	".ogg":  "audio/ogg",
	".opus": "audio/opus",
	".wav":  "audio/wav",
	".webm": "audio/webm",
}

var supportedMIMETypes = map[string]bool{
	"audio/aac":    true,
	"audio/flac":   true,
	"audio/mp4":    true,
	"audio/mpeg":   true,
	"audio/ogg":    true,
	"audio/opus":   true,
	"audio/wav":    true,
	"audio/webm":   true,
	"audio/x-caf":  true,
	"audio/x-flac": true,
	"audio/x-m4a":  true,
}

type engineState string

const (
	engineError        engineState = "error"
	engineLoading      engineState = "loading"
	engineReady        engineState = "ready"
	engineTranscribing engineState = "transcribing"
)

type lastTranscription struct {
	AudioSeconds float64 `json:"audioSeconds"`
	CompletedAt  string  `json:"completedAt"`
	ElapsedMS    int64   `json:"elapsedMs"`
}

type engineStatus struct {
	Backend           string
	Device            string
	Error             string
	LastTranscription *lastTranscription
	QueuedRequests    int
	State             engineState
}

type service struct {
	mu                sync.Mutex
	status            engineStatus
	model             *transcribe.Model
	converterPath     string
	artifactDirectory string
	waitingSlots      chan struct{}
	computeSlot       chan struct{}
	loadDone          chan struct{}
}

type upload struct {
	Contents     []byte
	Filename     string
	Language     string
	MIMEType     string
	ResponseType string
}

type transcriptionResult struct {
	AudioSeconds float64
	Text         string
}

type httpFailure struct {
	Status  int
	Message string
}

func (failure *httpFailure) Error() string {
	return failure.Message
}

func main() {
	port, err := servicePort(os.Getenv("TRANSCRIPTION_PORT"))
	if err != nil {
		logLine("error", "transcription.configuration.failed", map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	converterPath := strings.TrimSpace(os.Getenv("AFCONVERT_PATH"))
	if converterPath == "" {
		converterPath = "/usr/bin/afconvert"
	}
	artifactDirectory := strings.TrimSpace(os.Getenv("TRANSCRIBE_LIBRARY_DIR"))
	if artifactDirectory == "" {
		executable, executableError := os.Executable()
		if executableError != nil {
			logLine("error", "transcription.configuration.failed", map[string]any{"error": executableError.Error()})
			os.Exit(1)
		}
		artifactDirectory = filepath.Join(filepath.Dir(executable), "lib")
	}

	applicationContext, stopApplication := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopApplication()
	serverService := &service{
		status: engineStatus{
			Backend: "Metal",
			Device:  "Apple GPU",
			State:   engineLoading,
		},
		converterPath:     converterPath,
		artifactDirectory: artifactDirectory,
		waitingSlots:      make(chan struct{}, maximumQueuedRequests),
		computeSlot:       make(chan struct{}, 1),
		loadDone:          make(chan struct{}),
	}

	listener, err := net.Listen("tcp4", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		logLine("error", "transcription.listener.failed", map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	httpServer := &http.Server{
		Handler:           serverService,
		ReadHeaderTimeout: 30 * time.Second,
		ReadTimeout:       transcriptionTimeout + 10*time.Second,
		WriteTimeout:      transcriptionTimeout + 10*time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 * 1024,
		BaseContext: func(net.Listener) context.Context {
			return applicationContext
		},
	}
	logLine("info", "transcription.listening", map[string]any{"host": host, "port": port})
	go serverService.loadModel()

	serveDone := make(chan error, 1)
	go func() {
		serveDone <- httpServer.Serve(listener)
	}()
	select {
	case serveError := <-serveDone:
		if !errors.Is(serveError, http.ErrServerClosed) {
			logLine("error", "transcription.listener.failed", map[string]any{"error": serveError.Error()})
			stopApplication()
		}
	case <-applicationContext.Done():
	}

	shutdownContext, cancelShutdown := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelShutdown()
	if err := httpServer.Shutdown(shutdownContext); err != nil {
		logLine("error", "transcription.shutdown.failed", map[string]any{"error": err.Error()})
		_ = httpServer.Close()
	}
	<-serverService.loadDone
	serverService.mu.Lock()
	model := serverService.model
	serverService.model = nil
	serverService.mu.Unlock()
	model.Close()
}

func (service *service) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodGet && request.URL.Path == "/healthz" {
		writeJSON(response, http.StatusOK, service.health())
		return
	}
	if request.Method == http.MethodPost && request.URL.Path == "/v1/audio/transcriptions" {
		service.handleTranscription(response, request)
		return
	}
	writeJSON(response, http.StatusNotFound, map[string]any{
		"error": map[string]any{"message": "not found", "type": "invalid_request_error"},
	})
}

func (service *service) handleTranscription(response http.ResponseWriter, request *http.Request) {
	parsed, err := parseUpload(response, request)
	if err == nil {
		requestContext, cancel := context.WithTimeout(request.Context(), transcriptionTimeout)
		defer cancel()
		var result transcriptionResult
		result, err = service.transcribe(requestContext, parsed)
		if err == nil {
			switch parsed.ResponseType {
			case "text":
				writeText(response, http.StatusOK, result.Text)
			case "verbose_json":
				writeJSON(response, http.StatusOK, map[string]any{
					"duration": math.Round(result.AudioSeconds*1_000) / 1_000,
					"language": parsed.Language,
					"text":     result.Text,
				})
			default:
				writeJSON(response, http.StatusOK, map[string]any{"text": result.Text})
			}
			return
		}
	}
	if request.Context().Err() != nil {
		return
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		err = &httpFailure{Status: http.StatusRequestTimeout, Message: "transcription was cancelled"}
	}
	writeFailure(response, err)
	var failure *httpFailure
	if !errors.As(err, &failure) {
		logLine("error", "transcription.failed", map[string]any{"error": err.Error()})
	}
}

func (service *service) transcribe(ctx context.Context, parsed upload) (transcriptionResult, error) {
	service.mu.Lock()
	model := service.model
	state := service.status.State
	modelError := service.status.Error
	service.mu.Unlock()
	if model == nil || state == engineLoading || state == engineError {
		if modelError == "" {
			modelError = "the transcription model is still loading"
		}
		return transcriptionResult{}, &httpFailure{Status: http.StatusServiceUnavailable, Message: modelError}
	}

	select {
	case service.waitingSlots <- struct{}{}:
		service.mu.Lock()
		service.status.QueuedRequests++
		service.mu.Unlock()
	default:
		return transcriptionResult{}, &httpFailure{Status: http.StatusTooManyRequests, Message: "the transcription service queue is full"}
	}
	waiting := true
	defer func() {
		if waiting {
			<-service.waitingSlots
			service.mu.Lock()
			service.status.QueuedRequests--
			service.mu.Unlock()
		}
	}()

	select {
	case service.computeSlot <- struct{}{}:
		<-service.waitingSlots
		service.mu.Lock()
		service.status.QueuedRequests--
		service.status.State = engineTranscribing
		service.status.Error = ""
		service.mu.Unlock()
		waiting = false
	case <-ctx.Done():
		return transcriptionResult{}, ctx.Err()
	}
	defer func() {
		<-service.computeSlot
		service.mu.Lock()
		if service.status.State != engineError {
			service.status.State = engineReady
		}
		service.mu.Unlock()
	}()

	startedAt := time.Now()
	wav, err := audio.Decode(ctx, parsed.Contents, parsed.MIMEType, parsed.Filename, service.converterPath)
	if err != nil {
		return transcriptionResult{}, err
	}
	chunks := audio.Float32Chunks(wav, audio.QuietChunkBoundaries(wav))
	parts := make([]string, 0, len(chunks))
	for offset := 0; offset < len(chunks); offset += audio.BatchSize {
		end := min(len(chunks), offset+audio.BatchSize)
		texts, err := model.RunBatch(ctx, chunks[offset:end], parsed.Language)
		if err != nil {
			return transcriptionResult{}, err
		}
		for _, text := range texts {
			if text = strings.TrimSpace(text); text != "" {
				parts = append(parts, text)
			}
		}
	}
	text := strings.TrimSpace(strings.Join(parts, " "))
	if text == "" {
		return transcriptionResult{}, errors.New("Cohere returned an empty transcription")
	}

	audioSeconds := float64(wav.SampleCount) / float64(wav.SampleRate)
	elapsedMilliseconds := time.Since(startedAt).Milliseconds()
	completed := &lastTranscription{
		AudioSeconds: math.Round(audioSeconds*10) / 10,
		CompletedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		ElapsedMS:    elapsedMilliseconds,
	}
	service.mu.Lock()
	service.status.LastTranscription = completed
	service.mu.Unlock()
	logLine("info", "transcription.completed", map[string]any{
		"audioSeconds": completed.AudioSeconds,
		"elapsedMs":    completed.ElapsedMS,
	})
	return transcriptionResult{AudioSeconds: audioSeconds, Text: text}, nil
}

func parseUpload(response http.ResponseWriter, request *http.Request) (upload, error) {
	if !strings.HasPrefix(strings.ToLower(request.Header.Get("Content-Type")), "multipart/form-data;") {
		return upload{}, &httpFailure{Status: http.StatusUnsupportedMediaType, Message: "request body must be multipart form data"}
	}
	maximumRequestBytes := int64(maximumUploadBytes + requestOverheadBytes)
	if request.ContentLength > maximumRequestBytes {
		return upload{}, &httpFailure{Status: http.StatusRequestEntityTooLarge, Message: "request body is too large"}
	}
	request.Body = http.MaxBytesReader(response, request.Body, maximumRequestBytes)
	reader, err := request.MultipartReader()
	if err != nil {
		return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "request body is not valid multipart form data"}
	}

	allowedFields := map[string]bool{
		"file":                      true,
		"language":                  true,
		"model":                     true,
		"prompt":                    true,
		"response_format":           true,
		"temperature":               true,
		"timestamp_granularities[]": true,
	}
	fields := make(map[string][]string)
	parsed := upload{}
	fileCount := 0
	for {
		part, nextError := reader.NextPart()
		if errors.Is(nextError, io.EOF) {
			break
		}
		if nextError != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(nextError, &tooLarge) {
				return upload{}, &httpFailure{Status: http.StatusRequestEntityTooLarge, Message: "request body is too large"}
			}
			return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "request body is not valid multipart form data"}
		}
		name := part.FormName()
		if !allowedFields[name] {
			_ = part.Close()
			return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "unknown multipart field: " + name}
		}
		if name == "file" {
			fileCount++
			filename := part.FileName()
			mimeType := part.Header.Get("Content-Type")
			if fileCount > 1 || filename == "" {
				_ = part.Close()
				return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "file must contain exactly one audio upload"}
			}
			contents, readError := readPart(part, maximumUploadBytes)
			_ = part.Close()
			if readError != nil {
				return upload{}, readError
			}
			parsed.Contents = contents
			parsed.Filename = filename
			parsed.MIMEType = mimeType
			continue
		}
		if part.FileName() != "" {
			_ = part.Close()
			return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: name + " must appear at most once and contain text"}
		}
		value, readError := readPart(part, maximumMultipartFieldLen)
		_ = part.Close()
		if readError != nil {
			return upload{}, readError
		}
		fields[name] = append(fields[name], strings.TrimSpace(string(value)))
	}
	if fileCount != 1 {
		return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "file must contain exactly one audio upload"}
	}
	if len(parsed.Contents) == 0 {
		return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "audio upload was empty"}
	}

	responseType, err := oneTextField(fields, "response_format")
	if err != nil {
		return upload{}, err
	}
	if responseType == "" {
		responseType = "json"
	}
	if responseType != "json" && responseType != "text" && responseType != "verbose_json" {
		return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: "response_format must be json, text, or verbose_json"}
	}
	language, err := oneTextField(fields, "language")
	if err != nil {
		return upload{}, err
	}

	uploadedMIMEType := strings.ToLower(strings.TrimSpace(strings.SplitN(parsed.MIMEType, ";", 2)[0]))
	mimeType := uploadedMIMEType
	if !supportedMIMETypes[mimeType] {
		mimeType = mimeTypesByExtension[strings.ToLower(filepath.Ext(parsed.Filename))]
	}
	if mimeType == "" {
		filename := parsed.Filename
		if filename == "" {
			filename = "audio"
		}
		return upload{}, &httpFailure{Status: http.StatusBadRequest, Message: filename + " has an unsupported audio format"}
	}
	parsed.MIMEType = mimeType
	parsed.Language = language
	parsed.ResponseType = responseType
	return parsed, nil
}

func readPart(part *multipart.Part, limit int64) ([]byte, error) {
	contents, err := io.ReadAll(io.LimitReader(part, limit+1))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return nil, &httpFailure{Status: http.StatusRequestEntityTooLarge, Message: "request body is too large"}
		}
		return nil, &httpFailure{Status: http.StatusBadRequest, Message: "request body is not valid multipart form data"}
	}
	if int64(len(contents)) > limit {
		message := "multipart field is too large"
		if part.FormName() == "file" {
			message = "audio upload is too large"
		}
		return nil, &httpFailure{Status: http.StatusRequestEntityTooLarge, Message: message}
	}
	return contents, nil
}

func oneTextField(fields map[string][]string, name string) (string, error) {
	values := fields[name]
	if len(values) == 0 {
		return "", nil
	}
	if len(values) != 1 {
		return "", &httpFailure{Status: http.StatusBadRequest, Message: name + " must appear at most once and contain text"}
	}
	return values[0], nil
}

func (service *service) loadModel() {
	defer close(service.loadDone)
	modelPath := strings.TrimSpace(os.Getenv("TRANSCRIBE_MODEL"))
	if modelPath == "" {
		service.setLoadError("set TRANSCRIBE_MODEL before starting the transcription service")
		return
	}
	metadata, err := os.Stat(modelPath)
	if err != nil || !metadata.Mode().IsRegular() {
		service.setLoadError("TRANSCRIBE_MODEL does not name a readable file")
		return
	}
	file, err := os.Open(modelPath)
	if err != nil {
		service.setLoadError("TRANSCRIBE_MODEL does not name a readable file")
		return
	}
	_ = file.Close()

	model, err := transcribe.Load(modelPath, service.artifactDirectory)
	if err != nil {
		service.setLoadError(err.Error())
		return
	}
	backend := model.Backend()
	if strings.EqualFold(backend, "metal") {
		backend = "Metal"
	}
	service.mu.Lock()
	service.model = model
	service.status.Backend = backend
	service.status.Device = model.Device()
	service.status.State = engineReady
	service.status.Error = ""
	service.mu.Unlock()
	logLine("info", "transcription.ready", map[string]any{
		"backend": backend,
		"device":  model.Device(),
		"model":   audio.ModelName,
	})
}

func (service *service) setLoadError(message string) {
	service.mu.Lock()
	service.status.State = engineError
	service.status.Error = message
	service.mu.Unlock()
	logLine("error", "transcription.unavailable", map[string]any{"error": message})
}

func (service *service) health() map[string]any {
	service.mu.Lock()
	status := service.status
	service.mu.Unlock()
	return map[string]any{
		"backend":           status.Backend,
		"device":            status.Device,
		"error":             nilIfEmpty(status.Error),
		"lastTranscription": status.LastTranscription,
		"model":             audio.ModelName,
		"modelDisplayName":  modelDisplayName,
		"pid":               os.Getpid(),
		"queuedRequests":    status.QueuedRequests,
		"state":             status.State,
	}
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	contents, err := json.Marshal(value)
	if err != nil {
		contents = []byte(`{"error":{"message":"response serialization failed","type":"server_error"}}`)
		status = http.StatusInternalServerError
	}
	contents = append(contents, '\n')
	response.Header().Set("Cache-Control", "private, no-store")
	response.Header().Set("Content-Length", strconv.Itoa(len(contents)))
	response.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.WriteHeader(status)
	_, _ = response.Write(contents)
}

func writeText(response http.ResponseWriter, status int, text string) {
	contents := []byte(text + "\n")
	response.Header().Set("Cache-Control", "private, no-store")
	response.Header().Set("Content-Length", strconv.Itoa(len(contents)))
	response.Header().Set("Content-Type", "text/plain; charset=utf-8")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.WriteHeader(status)
	_, _ = response.Write(contents)
}

func writeFailure(response http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	message := "transcription failed"
	var failure *httpFailure
	if errors.As(err, &failure) {
		status = failure.Status
		message = failure.Message
	} else if err != nil {
		message = err.Error()
	}
	errorType := "server_error"
	if status < http.StatusInternalServerError {
		errorType = "invalid_request_error"
	}
	writeJSON(response, status, map[string]any{
		"error": map[string]any{"message": message, "type": errorType},
	})
}

func servicePort(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return defaultPort, nil
	}
	port, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || port < 1 || port > 65_535 {
		return 0, errors.New("TRANSCRIPTION_PORT must be an integer from 1 to 65535")
	}
	return port, nil
}

func nilIfEmpty(value string) any {
	if value == "" {
		return nil
	}
	return value
}

var logMu sync.Mutex

func logLine(level, event string, fields map[string]any) {
	record := make(map[string]any, len(fields)+6)
	for key, value := range fields {
		record[key] = value
	}
	record["v"] = 1
	record["ts"] = time.Now().UTC().Format(time.RFC3339Nano)
	record["level"] = level
	record["event"] = event
	record["service"] = "chinwag"
	record["pid"] = os.Getpid()
	contents, _ := json.Marshal(record)
	logMu.Lock()
	defer logMu.Unlock()
	stream := os.Stdout
	if level == "error" {
		stream = os.Stderr
	}
	_, _ = fmt.Fprintln(stream, string(contents))
}
