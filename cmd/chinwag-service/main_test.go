package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRejectsBrowserRequests(t *testing.T) {
	requests := []struct {
		name   string
		method string
		path   string
	}{
		{name: "health", method: http.MethodGet, path: "/healthz"},
		{name: "transcription", method: http.MethodPost, path: "/v1/audio/transcriptions"},
	}
	for _, requestCase := range requests {
		for _, header := range []string{"Origin", "Sec-Fetch-Site"} {
			t.Run(requestCase.name+"/"+header, func(t *testing.T) {
				request := httptest.NewRequest(requestCase.method, requestCase.path, nil)
				request.Header.Set(header, "https://example.com")
				response := httptest.NewRecorder()

				new(service).ServeHTTP(response, request)

				if response.Code != http.StatusForbidden {
					t.Fatalf("status = %d, want %d", response.Code, http.StatusForbidden)
				}
			})
		}
	}
}

func TestTranscriptionAcceptsNativeRequests(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/v1/audio/transcriptions", nil)
	response := httptest.NewRecorder()

	new(service).ServeHTTP(response, request)

	if response.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusUnsupportedMediaType)
	}
}
