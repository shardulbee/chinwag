package transcribe

/*
#cgo darwin,arm64 CFLAGS: -I${SRCDIR}
#cgo darwin,arm64 LDFLAGS: -L${SRCDIR}/../../artifacts/transcribe-native-macos-arm64-metal -ltranscribe

#include "transcribe.h"
#include <stdatomic.h>
#include <stdlib.h>

struct chinwag_abort_flag {
    atomic_bool aborted;
};

static struct chinwag_abort_flag * chinwag_abort_flag_new(void) {
    struct chinwag_abort_flag * flag = calloc(1, sizeof(*flag));
    if (flag != NULL) {
        atomic_init(&flag->aborted, false);
    }
    return flag;
}

static void chinwag_abort_flag_set(struct chinwag_abort_flag * flag) {
    if (flag != NULL) {
        atomic_store_explicit(&flag->aborted, true, memory_order_relaxed);
    }
}

static bool chinwag_should_abort(void * userdata) {
    struct chinwag_abort_flag * flag = userdata;
    return flag != NULL && atomic_load_explicit(&flag->aborted, memory_order_relaxed);
}

static void chinwag_set_abort_callback(
    struct transcribe_session * session,
    struct chinwag_abort_flag * flag
) {
    transcribe_set_abort_callback(session, chinwag_should_abort, flag);
}

static void chinwag_clear_abort_callback(struct transcribe_session * session) {
    transcribe_set_abort_callback(session, NULL, NULL);
}

static bool chinwag_abi_matches(void) {
    return sizeof(struct transcribe_model_load_params) ==
               transcribe_abi_struct_size(TRANSCRIBE_ABI_MODEL_LOAD_PARAMS) &&
           sizeof(struct transcribe_session_params) ==
               transcribe_abi_struct_size(TRANSCRIBE_ABI_SESSION_PARAMS) &&
           sizeof(struct transcribe_run_params) ==
               transcribe_abi_struct_size(TRANSCRIBE_ABI_RUN_PARAMS) &&
           sizeof(struct transcribe_device_info) ==
               transcribe_abi_struct_size(TRANSCRIBE_ABI_DEVICE_INFO);
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"unsafe"
)

const nativeVersion = "0.2.1"

var initializeLogging sync.Once

type Model struct {
	pointer *C.struct_transcribe_model
	backend string
	device  string
}

func Load(modelPath, artifactDirectory string) (*Model, error) {
	initializeLogging.Do(func() {
		C.transcribe_log_set(nil, nil)
	})

	if version := cString(C.transcribe_version()); version != nativeVersion {
		return nil, fmt.Errorf("native transcription library is version %s, expected %s", version, nativeVersion)
	}
	if !bool(C.chinwag_abi_matches()) {
		return nil, errors.New("native transcription library ABI does not match the vendored header")
	}

	artifactPath := C.CString(artifactDirectory)
	status := C.transcribe_init_backends(artifactPath)
	C.free(unsafe.Pointer(artifactPath))
	if status != C.TRANSCRIBE_OK {
		status = C.transcribe_init_backends_default()
	}
	if status != C.TRANSCRIBE_OK {
		return nil, statusError("initialize native backends", status)
	}

	path := C.CString(modelPath)
	defer C.free(unsafe.Pointer(path))
	var parameters C.struct_transcribe_model_load_params
	C.transcribe_model_load_params_init(&parameters)
	parameters.backend = C.TRANSCRIBE_BACKEND_METAL
	var pointer *C.struct_transcribe_model
	status = C.transcribe_model_load_file(path, &parameters, &pointer)
	if status != C.TRANSCRIBE_OK {
		return nil, statusError("load transcription model", status)
	}

	model := &Model{
		pointer: pointer,
		backend: "Metal",
		device:  "Apple GPU",
	}
	if device := C.transcribe_model_device(pointer); device != nil {
		var information C.struct_transcribe_device_info
		C.transcribe_device_info_init(&information)
		if C.transcribe_device_get_info(device, &information) == C.TRANSCRIBE_OK {
			if description := cString(information.description); description != "" {
				model.device = description
			} else if name := cString(information.name); name != "" {
				model.device = name
			}
		}
	}
	return model, nil
}

func (model *Model) Backend() string {
	return model.backend
}

func (model *Model) Device() string {
	return model.device
}

func (model *Model) Close() {
	if model == nil || model.pointer == nil {
		return
	}
	C.transcribe_model_free(model.pointer)
	model.pointer = nil
}

func (model *Model) RunBatch(ctx context.Context, chunks [][]float32, language string) ([]string, error) {
	if model == nil || model.pointer == nil {
		return nil, errors.New("transcription model is not loaded")
	}
	if len(chunks) == 0 {
		return nil, errors.New("transcription batch was empty")
	}

	var sessionParameters C.struct_transcribe_session_params
	C.transcribe_session_params_init(&sessionParameters)
	var session *C.struct_transcribe_session
	if status := C.transcribe_session_init(model.pointer, &sessionParameters, &session); status != C.TRANSCRIBE_OK {
		return nil, statusError("create transcription session", status)
	}
	defer C.transcribe_session_free(session)

	abortFlag := C.chinwag_abort_flag_new()
	if abortFlag == nil {
		return nil, errors.New("allocate transcription cancellation flag")
	}
	C.chinwag_set_abort_callback(session, abortFlag)
	stopCancellation := make(chan struct{})
	cancellationStopped := make(chan struct{})
	go func() {
		defer close(cancellationStopped)
		select {
		case <-ctx.Done():
			C.chinwag_abort_flag_set(abortFlag)
		case <-stopCancellation:
		}
	}()
	defer func() {
		close(stopCancellation)
		<-cancellationStopped
		C.chinwag_clear_abort_callback(session)
		C.free(unsafe.Pointer(abortFlag))
	}()

	pointerMemory := C.calloc(C.size_t(len(chunks)), C.size_t(unsafe.Sizeof(uintptr(0))))
	lengthMemory := C.calloc(C.size_t(len(chunks)), C.size_t(unsafe.Sizeof(C.int(0))))
	if pointerMemory == nil || lengthMemory == nil {
		C.free(pointerMemory)
		C.free(lengthMemory)
		return nil, errors.New("allocate transcription batch")
	}
	defer C.free(pointerMemory)
	defer C.free(lengthMemory)
	pointers := unsafe.Slice((**C.float)(pointerMemory), len(chunks))
	lengths := unsafe.Slice((*C.int)(lengthMemory), len(chunks))
	defer func() {
		for _, pointer := range pointers {
			C.free(unsafe.Pointer(pointer))
		}
	}()
	for index, chunk := range chunks {
		if len(chunk) == 0 {
			return nil, fmt.Errorf("transcription chunk %d was empty", index)
		}
		memory := C.malloc(C.size_t(len(chunk)) * C.size_t(unsafe.Sizeof(C.float(0))))
		if memory == nil {
			return nil, errors.New("allocate transcription audio")
		}
		pointers[index] = (*C.float)(memory)
		lengths[index] = C.int(len(chunk))
		destination := unsafe.Slice((*C.float)(memory), len(chunk))
		for sampleIndex, sample := range chunk {
			destination[sampleIndex] = C.float(sample)
		}
	}

	var runParameters C.struct_transcribe_run_params
	C.transcribe_run_params_init(&runParameters)
	runParameters.timestamps = C.TRANSCRIBE_TIMESTAMPS_NONE
	var languageValue *C.char
	if language != "" {
		languageValue = C.CString(language)
		defer C.free(unsafe.Pointer(languageValue))
		runParameters.language = languageValue
	}

	status := C.transcribe_run_batch(
		session,
		(**C.float)(pointerMemory),
		(*C.int)(lengthMemory),
		C.int(len(chunks)),
		&runParameters,
	)
	runtime.KeepAlive(model)
	if ctxError := ctx.Err(); ctxError != nil {
		return nil, ctxError
	}
	if status != C.TRANSCRIBE_OK {
		return nil, statusError("run transcription batch", status)
	}
	if count := int(C.transcribe_batch_n_results(session)); count != len(chunks) {
		return nil, fmt.Errorf("native transcription returned %d results for %d chunks", count, len(chunks))
	}

	texts := make([]string, len(chunks))
	for index := range chunks {
		itemStatus := C.transcribe_batch_status(session, C.int(index))
		if itemStatus != C.TRANSCRIBE_OK {
			return nil, statusError(fmt.Sprintf("transcribe chunk %d", index), itemStatus)
		}
		texts[index] = strings.TrimSpace(cString(C.transcribe_batch_full_text(session, C.int(index))))
	}
	return texts, nil
}

func statusError(action string, status C.transcribe_status) error {
	return fmt.Errorf("%s: %s (status %d)", action, cString(C.transcribe_status_string(C.int(status))), int(status))
}

func cString(value *C.char) string {
	if value == nil {
		return ""
	}
	return C.GoString(value)
}
