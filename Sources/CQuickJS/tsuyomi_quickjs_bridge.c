/*
 * SPDX-License-Identifier: AGPL-3.0-only
 */
#include "tsuyomi_quickjs_bridge.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs.h"

#define TSUYOMI_QJS_MAX_HANDLES 64
#define TSUYOMI_QJS_MAX_ARGUMENTS 32

typedef struct {
    tsuyomi_qjs_handle identifier;
    JSRuntime *runtime;
    JSContext *context;
    atomic_bool cancelled;
    atomic_llong deadline_nanos;
} tsuyomi_qjs_runtime;

static tsuyomi_qjs_runtime g_handles[TSUYOMI_QJS_MAX_HANDLES];
static pthread_mutex_t g_handles_mutex = PTHREAD_MUTEX_INITIALIZER;
static tsuyomi_qjs_handle g_next_handle = 1;

static int64_t monotonic_nanos(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000000000LL + (int64_t)now.tv_nsec;
}

static int interrupt_handler(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    tsuyomi_qjs_runtime *state = (tsuyomi_qjs_runtime *)opaque;
    if (atomic_load_explicit(&state->cancelled, memory_order_relaxed)) return 1;
    return monotonic_nanos() >= atomic_load_explicit(&state->deadline_nanos, memory_order_relaxed);
}

/* An extension is one self-contained module: resolving any specifier is a policy failure. */
static JSModuleDef *reject_module_loader(JSContext *context, const char *module_name, void *opaque) {
    (void)opaque;
    (void)module_name;
    JS_ThrowReferenceError(context, "module import is not available");
    return NULL;
}

static tsuyomi_qjs_runtime *lookup(tsuyomi_qjs_handle handle) {
    if (handle <= 0) return NULL;
    tsuyomi_qjs_runtime *found = NULL;
    pthread_mutex_lock(&g_handles_mutex);
    for (int index = 0; index < TSUYOMI_QJS_MAX_HANDLES; ++index) {
        if (g_handles[index].identifier == handle) {
            found = &g_handles[index];
            break;
        }
    }
    pthread_mutex_unlock(&g_handles_mutex);
    return found;
}

tsuyomi_qjs_handle tsuyomi_qjs_create(int64_t memory_limit_bytes, int64_t max_stack_size_bytes) {
    tsuyomi_qjs_runtime *slot = NULL;
    pthread_mutex_lock(&g_handles_mutex);
    for (int index = 0; index < TSUYOMI_QJS_MAX_HANDLES; ++index) {
        if (g_handles[index].identifier == 0) {
            slot = &g_handles[index];
            break;
        }
    }
    if (slot == NULL) {
        pthread_mutex_unlock(&g_handles_mutex);
        return 0;
    }
    slot->identifier = g_next_handle++;
    pthread_mutex_unlock(&g_handles_mutex);

    slot->runtime = JS_NewRuntime();
    if (slot->runtime == NULL) {
        pthread_mutex_lock(&g_handles_mutex);
        slot->identifier = 0;
        pthread_mutex_unlock(&g_handles_mutex);
        return 0;
    }
    atomic_store_explicit(&slot->cancelled, false, memory_order_relaxed);
    atomic_store_explicit(&slot->deadline_nanos, 0, memory_order_relaxed);
    JS_SetMemoryLimit(slot->runtime, (size_t)memory_limit_bytes);
    JS_SetMaxStackSize(slot->runtime, (size_t)max_stack_size_bytes);
    JS_SetInterruptHandler(slot->runtime, interrupt_handler, slot);
    JS_SetModuleLoaderFunc(slot->runtime, NULL, reject_module_loader, NULL);
    slot->context = JS_NewContext(slot->runtime);
    if (slot->context == NULL) {
        JS_FreeRuntime(slot->runtime);
        slot->runtime = NULL;
        pthread_mutex_lock(&g_handles_mutex);
        slot->identifier = 0;
        pthread_mutex_unlock(&g_handles_mutex);
        return 0;
    }
    return slot->identifier;
}

tsuyomi_qjs_status tsuyomi_qjs_prepare_operation(tsuyomi_qjs_handle handle, int32_t wall_time_millis) {
    tsuyomi_qjs_runtime *state = lookup(handle);
    if (state == NULL || state->context == NULL) return TSUYOMI_QJS_CLOSED;
    atomic_store_explicit(&state->cancelled, false, memory_order_relaxed);
    atomic_store_explicit(
        &state->deadline_nanos,
        monotonic_nanos() + (int64_t)wall_time_millis * 1000000LL,
        memory_order_relaxed);
    /* The stack base is re-read per operation so the stack bound stays correct even when the
       serial executor runs consecutive operations on different threads. */
    JS_UpdateStackTop(state->runtime);
    JS_ResetUncatchableError(state->context);
    return TSUYOMI_QJS_OK;
}

static tsuyomi_qjs_status classify_failure(tsuyomi_qjs_runtime *state) {
    const bool cancelled = atomic_load_explicit(&state->cancelled, memory_order_relaxed);
    const bool timed_out = monotonic_nanos() >= atomic_load_explicit(&state->deadline_nanos, memory_order_relaxed);
    JSValue exception = JS_GetException(state->context);
    JSValue message_value = JS_GetPropertyStr(state->context, exception, "message");
    size_t message_length = 0;
    const char *message = JS_ToCStringLen(state->context, &message_length, message_value);
    bool out_of_memory = false;
    bool import_disallowed = false;
    if (message != NULL) {
        out_of_memory = strstr(message, "out of memory") != NULL;
        import_disallowed = strstr(message, "module import is not available") != NULL;
        JS_FreeCString(state->context, message);
    }
    JS_FreeValue(state->context, message_value);
    JS_FreeValue(state->context, exception);
    if (cancelled) return TSUYOMI_QJS_CANCELLED;
    if (timed_out) return TSUYOMI_QJS_EXECUTION_LIMIT;
    if (out_of_memory) return TSUYOMI_QJS_MEMORY_LIMIT;
    if (import_disallowed) return TSUYOMI_QJS_IMPORT_DISALLOWED;
    return TSUYOMI_QJS_JS_EXCEPTION;
}

static tsuyomi_qjs_status run_pending_jobs(tsuyomi_qjs_runtime *state) {
    while (JS_IsJobPending(state->runtime)) {
        JSContext *job_context = NULL;
        if (JS_ExecutePendingJob(state->runtime, &job_context) < 0) return classify_failure(state);
    }
    return TSUYOMI_QJS_OK;
}

static char *null_terminated(const uint8_t *bytes, size_t length) {
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) return NULL;
    if (length > 0) memcpy(copy, bytes, length);
    copy[length] = '\0';
    return copy;
}

tsuyomi_qjs_status tsuyomi_qjs_evaluate_module(
    tsuyomi_qjs_handle handle,
    const uint8_t *source,
    size_t source_length,
    const uint8_t *filename,
    size_t filename_length) {
    tsuyomi_qjs_runtime *state = lookup(handle);
    if (state == NULL || state->context == NULL) return TSUYOMI_QJS_CLOSED;
    char *source_text = null_terminated(source, source_length);
    char *filename_text = null_terminated(filename, filename_length);
    if (source_text == NULL || filename_text == NULL) {
        free(source_text);
        free(filename_text);
        return TSUYOMI_QJS_MEMORY_LIMIT;
    }
    JSValue result = JS_Eval(
        state->context,
        source_text,
        source_length,
        filename_text,
        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_BACKTRACE_BARRIER);
    free(source_text);
    free(filename_text);
    if (JS_IsException(result)) {
        JS_FreeValue(state->context, result);
        return classify_failure(state);
    }
    JS_FreeValue(state->context, result);
    return run_pending_jobs(state);
}

tsuyomi_qjs_status tsuyomi_qjs_call_json(
    tsuyomi_qjs_handle handle,
    const uint8_t *function_name,
    size_t function_name_length,
    const uint8_t *arguments_json,
    size_t arguments_json_length,
    uint8_t **out,
    size_t *out_length) {
    tsuyomi_qjs_runtime *state = lookup(handle);
    if (state == NULL || state->context == NULL) return TSUYOMI_QJS_CLOSED;
    *out = NULL;
    *out_length = 0;

    char *name = null_terminated(function_name, function_name_length);
    char *arguments_text = null_terminated(arguments_json, arguments_json_length);
    if (name == NULL || arguments_text == NULL) {
        free(name);
        free(arguments_text);
        return TSUYOMI_QJS_MEMORY_LIMIT;
    }

    JSValue global = JS_GetGlobalObject(state->context);
    JSValue extension = JS_GetPropertyStr(state->context, global, "tsuyomiExtension");
    JSValue function = JS_GetPropertyStr(state->context, extension, name);
    free(name);
    if (!JS_IsFunction(state->context, function)) {
        free(arguments_text);
        JS_FreeValue(state->context, function);
        JS_FreeValue(state->context, extension);
        JS_FreeValue(state->context, global);
        return TSUYOMI_QJS_MISSING_FUNCTION;
    }

    JSValue arguments = JS_ParseJSON(
        state->context, arguments_text, arguments_json_length, "<host-arguments>");
    free(arguments_text);
    if (JS_IsException(arguments) || !JS_IsArray(arguments)) {
        JS_FreeValue(state->context, arguments);
        JS_FreeValue(state->context, function);
        JS_FreeValue(state->context, extension);
        JS_FreeValue(state->context, global);
        if (JS_HasException(state->context)) JS_FreeValue(state->context, JS_GetException(state->context));
        return TSUYOMI_QJS_INVALID_ARGUMENTS;
    }

    JSValue length_value = JS_GetPropertyStr(state->context, arguments, "length");
    int64_t argument_count = 0;
    const int length_status = JS_ToInt64(state->context, &argument_count, length_value);
    JS_FreeValue(state->context, length_value);
    if (length_status < 0 || argument_count < 0 || argument_count > TSUYOMI_QJS_MAX_ARGUMENTS) {
        JS_FreeValue(state->context, arguments);
        JS_FreeValue(state->context, function);
        JS_FreeValue(state->context, extension);
        JS_FreeValue(state->context, global);
        return TSUYOMI_QJS_INVALID_ARGUMENTS;
    }

    JSValue values[TSUYOMI_QJS_MAX_ARGUMENTS];
    for (int index = 0; index < (int)argument_count; ++index) {
        values[index] = JS_GetPropertyUint32(state->context, arguments, (uint32_t)index);
    }
    JSValue result = JS_Call(state->context, function, extension, (int)argument_count, values);
    for (int index = 0; index < (int)argument_count; ++index) {
        JS_FreeValue(state->context, values[index]);
    }
    JS_FreeValue(state->context, arguments);
    JS_FreeValue(state->context, function);
    JS_FreeValue(state->context, extension);
    JS_FreeValue(state->context, global);
    if (JS_IsException(result)) {
        JS_FreeValue(state->context, result);
        return classify_failure(state);
    }
    const tsuyomi_qjs_status jobs = run_pending_jobs(state);
    if (jobs != TSUYOMI_QJS_OK) {
        JS_FreeValue(state->context, result);
        return jobs;
    }

    JSValue json = JS_JSONStringify(state->context, result, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(state->context, result);
    if (JS_IsException(json) || JS_IsUndefined(json)) {
        const bool had_exception = JS_HasException(state->context);
        JS_FreeValue(state->context, json);
        return had_exception ? classify_failure(state) : TSUYOMI_QJS_NON_JSON_RESULT;
    }
    size_t output_size = 0;
    const char *output = JS_ToCStringLen(state->context, &output_size, json);
    JS_FreeValue(state->context, json);
    if (output == NULL) return classify_failure(state);
    uint8_t *buffer = (uint8_t *)malloc(output_size > 0 ? output_size : 1);
    if (buffer == NULL) {
        JS_FreeCString(state->context, output);
        return TSUYOMI_QJS_MEMORY_LIMIT;
    }
    if (output_size > 0) memcpy(buffer, output, output_size);
    JS_FreeCString(state->context, output);
    *out = buffer;
    *out_length = output_size;
    return TSUYOMI_QJS_OK;
}

void tsuyomi_qjs_free_buffer(uint8_t *buffer) {
    free(buffer);
}

void tsuyomi_qjs_cancel(tsuyomi_qjs_handle handle) {
    tsuyomi_qjs_runtime *state = lookup(handle);
    if (state != NULL) atomic_store_explicit(&state->cancelled, true, memory_order_relaxed);
}

void tsuyomi_qjs_close(tsuyomi_qjs_handle handle) {
    tsuyomi_qjs_runtime *state = lookup(handle);
    if (state == NULL) return;
    atomic_store_explicit(&state->cancelled, true, memory_order_relaxed);
    if (state->context != NULL) {
        JS_FreeContext(state->context);
        state->context = NULL;
    }
    if (state->runtime != NULL) {
        JS_FreeRuntime(state->runtime);
        state->runtime = NULL;
    }
    pthread_mutex_lock(&g_handles_mutex);
    state->identifier = 0;
    pthread_mutex_unlock(&g_handles_mutex);
}
