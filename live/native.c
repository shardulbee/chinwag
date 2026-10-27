// Narrow Python FFI; the vendored header owns all transcribe.cpp layouts.
#include "transcribe.h"

int live_init(const char *directory) {
    transcribe_log_set(NULL, NULL);
    return transcribe_init_backends(directory);
}

int live_load(const char *path, struct transcribe_model **model) {
    struct transcribe_model_load_params params;
    transcribe_model_load_params_init(&params);
    params.backend = TRANSCRIBE_BACKEND_METAL;
    return transcribe_model_load_file(path, &params, model);
}

int live_begin(struct transcribe_model *model, const char *language,
               struct transcribe_session **session) {
    struct transcribe_session_params params;
    transcribe_session_params_init(&params);
    int status = transcribe_session_init(model, &params, session);
    if (status) return status;
    struct transcribe_run_params run;
    transcribe_run_params_init(&run);
    run.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
    run.language = language;
    status = transcribe_stream_begin(*session, &run, NULL);
    if (status) { transcribe_session_free(*session); *session = NULL; }
    return status;
}

int live_feed(struct transcribe_session *session, const float *pcm, int count) {
    return transcribe_stream_feed(session, pcm, count, NULL);
}

int live_end(struct transcribe_session *session) {
    int status = transcribe_stream_finalize(session, NULL);
    if (!status && transcribe_was_truncated(session)) return TRANSCRIBE_ERR_OUTPUT_TRUNCATED;
    return status;
}
