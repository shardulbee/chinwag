#include "Chinwag-Bridging-Header.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct chinwag_native_abort { atomic_bool aborted; };

chinwag_native_abort * chinwag_native_abort_new(void) {
    chinwag_native_abort * flag = calloc(1, sizeof(*flag));
    if (flag) atomic_init(&flag->aborted, false);
    return flag;
}

void chinwag_native_abort_set(chinwag_native_abort * flag) {
    if (flag) atomic_store_explicit(&flag->aborted, true, memory_order_relaxed);
}

void chinwag_native_abort_free(chinwag_native_abort * flag) { free(flag); }

static bool should_abort(void * userdata) {
    chinwag_native_abort * flag = userdata;
    return flag && atomic_load_explicit(&flag->aborted, memory_order_relaxed);
}

bool chinwag_native_abi_matches(void) {
    return sizeof(struct transcribe_model_load_params) == transcribe_abi_struct_size(TRANSCRIBE_ABI_MODEL_LOAD_PARAMS) &&
           sizeof(struct transcribe_session_params) == transcribe_abi_struct_size(TRANSCRIBE_ABI_SESSION_PARAMS) &&
           sizeof(struct transcribe_run_params) == transcribe_abi_struct_size(TRANSCRIBE_ABI_RUN_PARAMS) &&
           sizeof(struct transcribe_device_info) == transcribe_abi_struct_size(TRANSCRIBE_ABI_DEVICE_INFO);
}

int chinwag_native_run_batch(struct transcribe_model * model, const float * const * samples,
                             const int * lengths, int count, const char * language,
                             chinwag_native_abort * abort_flag, char *** texts, int * result_count) {
    *texts = NULL; *result_count = 0;
    struct transcribe_session_params session_params;
    transcribe_session_params_init(&session_params);
    struct transcribe_session * session = NULL;
    int status = transcribe_session_init(model, &session_params, &session);
    if (status != TRANSCRIBE_OK) return status;
    transcribe_set_abort_callback(session, should_abort, abort_flag);
    struct transcribe_run_params run_params;
    transcribe_run_params_init(&run_params);
    run_params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
    run_params.language = language;
    status = transcribe_run_batch(session, samples, lengths, count, &run_params);
    if (status == TRANSCRIBE_OK) {
        int n = transcribe_batch_n_results(session);
        if (n != count) status = TRANSCRIBE_ERR_BACKEND;
        else {
            char ** copies = calloc((size_t)n, sizeof(*copies));
            if (!copies) status = TRANSCRIBE_ERR_OOM;
            for (int i = 0; status == TRANSCRIBE_OK && i < n; i++) {
                status = transcribe_batch_status(session, i);
                if (status == TRANSCRIBE_OK) {
                    const char * text = transcribe_batch_full_text(session, i);
                    copies[i] = strdup(text ? text : "");
                    if (!copies[i]) status = TRANSCRIBE_ERR_OOM;
                }
            }
            if (status == TRANSCRIBE_OK) { *texts = copies; *result_count = n; }
            else chinwag_native_texts_free(copies, n);
        }
    }
    transcribe_set_abort_callback(session, NULL, NULL);
    transcribe_session_free(session);
    return status;
}

void chinwag_native_texts_free(char ** texts, int count) {
    if (!texts) return;
    for (int i = 0; i < count; i++) free(texts[i]);
    free(texts);
}
