#ifndef CHINWAG_NATIVE_BRIDGE_H
#define CHINWAG_NATIVE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

typedef struct chinwag_native_abort chinwag_native_abort;

chinwag_native_abort * chinwag_native_abort_new(void);
void chinwag_native_abort_set(chinwag_native_abort * flag);
void chinwag_native_abort_free(chinwag_native_abort * flag);

bool chinwag_native_abi_matches(void);
int chinwag_native_run_batch(
    struct transcribe_model * model,
    const float * const * samples,
    const int * lengths,
    int count,
    const char * language,
    chinwag_native_abort * abort_flag,
    char *** texts,
    int * result_count);
void chinwag_native_texts_free(char ** texts, int count);

#endif
