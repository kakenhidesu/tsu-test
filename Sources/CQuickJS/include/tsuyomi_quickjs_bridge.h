/*
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * The only surface Swift may use to reach QuickJS. Extension code receives no host object: values
 * cross this boundary as JSON bytes and nothing else (hxp-host-api-v1 §Isolation).
 */
#ifndef TSUYOMI_QUICKJS_BRIDGE_H
#define TSUYOMI_QUICKJS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Stable failure codes; they mirror the Android bridge one for one. */
typedef enum {
    TSUYOMI_QJS_OK = 0,
    TSUYOMI_QJS_NATIVE_UNAVAILABLE = 1,
    TSUYOMI_QJS_CLOSED = 2,
    TSUYOMI_QJS_CANCELLED = 3,
    TSUYOMI_QJS_EXECUTION_LIMIT = 4,
    TSUYOMI_QJS_MEMORY_LIMIT = 5,
    TSUYOMI_QJS_JS_EXCEPTION = 6,
    TSUYOMI_QJS_MISSING_FUNCTION = 7,
    TSUYOMI_QJS_INVALID_ARGUMENTS = 8,
    TSUYOMI_QJS_NON_JSON_RESULT = 9,
    TSUYOMI_QJS_IMPORT_DISALLOWED = 10
} tsuyomi_qjs_status;

/** Opaque runtime handle. One handle is one QuickJS runtime plus its single context. */
typedef int64_t tsuyomi_qjs_handle;

/**
 * Creates a runtime with a hard memory limit and stack bound. Returns 0 on failure.
 */
tsuyomi_qjs_handle tsuyomi_qjs_create(int64_t memory_limit_bytes, int64_t max_stack_size_bytes);

/** Arms the interrupt handler for one operation: clears cancellation and sets the wall deadline. */
tsuyomi_qjs_status tsuyomi_qjs_prepare_operation(tsuyomi_qjs_handle handle, int32_t wall_time_millis);

/** Evaluates one ES module. Every `import` is refused by the module loader. */
tsuyomi_qjs_status tsuyomi_qjs_evaluate_module(
    tsuyomi_qjs_handle handle,
    const uint8_t *source,
    size_t source_length,
    const uint8_t *filename,
    size_t filename_length);

/**
 * Calls `globalThis.tsuyomiExtension.<function_name>(...arguments)` where `arguments_json` is a JSON
 * array. On success `*out` receives a malloc'd JSON buffer the caller frees with
 * `tsuyomi_qjs_free_buffer`.
 */
tsuyomi_qjs_status tsuyomi_qjs_call_json(
    tsuyomi_qjs_handle handle,
    const uint8_t *function_name,
    size_t function_name_length,
    const uint8_t *arguments_json,
    size_t arguments_json_length,
    uint8_t **out,
    size_t *out_length);

void tsuyomi_qjs_free_buffer(uint8_t *buffer);

/** Sets the cancellation flag; the interrupt handler observes it from any thread. */
void tsuyomi_qjs_cancel(tsuyomi_qjs_handle handle);

/** Frees the context and runtime. The handle is invalid afterwards. */
void tsuyomi_qjs_close(tsuyomi_qjs_handle handle);

#ifdef __cplusplus
}
#endif

#endif /* TSUYOMI_QUICKJS_BRIDGE_H */
