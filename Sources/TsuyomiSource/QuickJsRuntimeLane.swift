// SPDX-License-Identifier: AGPL-3.0-only

import CQuickJS
import Foundation
import os

public let quickJsNgVersion = "0.16.1"

public struct QuickJsRuntimeLimits: Hashable, Sendable {
    public static let memoryRange: ClosedRange<Int64> = 1_048_576...67_108_864
    public static let wallTimeRange: ClosedRange<Int> = 100...30_000
    public static let stackSizeBytes: Int64 = 512 * 1024

    public let maximumMemoryBytes: Int64
    public let maximumExecutionWallTimeMs: Int

    public init(maximumMemoryBytes: Int64, maximumExecutionWallTimeMs: Int) throws {
        guard QuickJsRuntimeLimits.memoryRange.contains(maximumMemoryBytes) else {
            throw QuickJsRuntimeError.nativeUnavailable
        }
        guard QuickJsRuntimeLimits.wallTimeRange.contains(maximumExecutionWallTimeMs) else {
            throw QuickJsRuntimeError.nativeUnavailable
        }
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumExecutionWallTimeMs = maximumExecutionWallTimeMs
    }
}

public enum QuickJsRuntimeError: String, Error, Equatable, Sendable, CaseIterable {
    case nativeUnavailable = "NATIVE_UNAVAILABLE"
    case memoryLimit = "MEMORY_LIMIT"
    case executionLimit = "EXECUTION_LIMIT"
    case cancelled = "CANCELLED"
    case jsException = "JS_EXCEPTION"
    case missingFunction = "MISSING_FUNCTION"
    case invalidArguments = "INVALID_ARGUMENTS"
    case nonJsonResult = "NON_JSON_RESULT"
    case closed = "CLOSED"

    /// A terminal execution failure leaves the context in an unknown state, so it is discarded and
    /// rebuilt from the saved verified module before the next operation runs.
    var invalidatesContext: Bool {
        switch self {
        case .missingFunction, .invalidArguments, .nonJsonResult, .closed: return false
        default: return true
        }
    }

    static func mapped(_ status: tsuyomi_qjs_status) -> QuickJsRuntimeError {
        switch status {
        case TSUYOMI_QJS_CLOSED: return .closed
        case TSUYOMI_QJS_CANCELLED: return .cancelled
        case TSUYOMI_QJS_EXECUTION_LIMIT: return .executionLimit
        case TSUYOMI_QJS_MEMORY_LIMIT: return .memoryLimit
        case TSUYOMI_QJS_MISSING_FUNCTION: return .missingFunction
        case TSUYOMI_QJS_INVALID_ARGUMENTS: return .invalidArguments
        case TSUYOMI_QJS_NON_JSON_RESULT: return .nonJsonResult
        case TSUYOMI_QJS_NATIVE_UNAVAILABLE: return .nativeUnavailable
        default: return .jsException
        }
    }
}

/// Owns one QuickJS-ng runtime for one installed extension version. Operations are serialised by
/// actor isolation, and a terminal failure discards the context; the next operation recreates it
/// from the saved verified module before serving the caller.
public actor QuickJsRuntimeLane {
    private struct VerifiedModule {
        let source: Data
        let filename: Data
    }

    private let limits: QuickJsRuntimeLimits
    private var handle: tsuyomi_qjs_handle
    private var verifiedModule: VerifiedModule?
    private var resetRequired = false
    private var isClosed = false
    private let activeOperation = OSAllocatedUnfairLock<tsuyomi_qjs_handle>(initialState: 0)

    public init(limits: QuickJsRuntimeLimits) throws {
        self.limits = limits
        self.handle = tsuyomi_qjs_create(limits.maximumMemoryBytes, QuickJsRuntimeLimits.stackSizeBytes)
        guard handle != 0 else { throw QuickJsRuntimeError.nativeUnavailable }
    }

    deinit {
        if handle != 0 { tsuyomi_qjs_close(handle) }
    }

    public func evaluateModule(source: Data, filename: String) throws {
        guard !source.isEmpty, source.count <= 8 * 1024 * 1024 else {
            throw QuickJsRuntimeError.invalidArguments
        }
        guard QuickJsRuntimeLane.isModuleFilename(filename) else { throw QuickJsRuntimeError.invalidArguments }
        let module = VerifiedModule(source: source, filename: Data(filename.utf8))
        try perform { handle in
            try QuickJsRuntimeLane.evaluate(handle, module)
        }
        verifiedModule = module
    }

    public func callJson(functionName: String, argumentsJson: String) throws -> String {
        guard QuickJsRuntimeLane.isFunctionName(functionName) else {
            throw QuickJsRuntimeError.invalidArguments
        }
        let arguments = Data(argumentsJson.utf8)
        guard arguments.count <= 8 * 1024 * 1024 else { throw QuickJsRuntimeError.invalidArguments }
        let name = Data(functionName.utf8)
        let output = try perform { handle -> Data in
            var buffer: UnsafeMutablePointer<UInt8>?
            var length = 0
            let status = name.withUnsafeBytes { namePointer in
                arguments.withUnsafeBytes { argumentPointer in
                    tsuyomi_qjs_call_json(
                        handle,
                        namePointer.bindMemory(to: UInt8.self).baseAddress,
                        name.count,
                        argumentPointer.bindMemory(to: UInt8.self).baseAddress,
                        arguments.count,
                        &buffer,
                        &length
                    )
                }
            }
            guard status == TSUYOMI_QJS_OK else { throw QuickJsRuntimeError.mapped(status) }
            defer { tsuyomi_qjs_free_buffer(buffer) }
            guard let buffer else { throw QuickJsRuntimeError.nonJsonResult }
            return Data(bytes: buffer, count: length)
        }
        guard let text = String(data: output, encoding: .utf8) else {
            throw QuickJsRuntimeError.nonJsonResult
        }
        return text
    }

    /// Cancels the operation currently running on this lane. It is safe to call from any task: the
    /// interrupt handler observes the flag from inside the interpreter loop.
    public nonisolated func cancelActiveOperation() {
        activeOperation.withLock { active in
            if active != 0 { tsuyomi_qjs_cancel(active) }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let active = handle
        handle = 0
        if active != 0 { tsuyomi_qjs_close(active) }
    }

    private func perform<T>(_ operation: (tsuyomi_qjs_handle) throws -> T) throws -> T {
        guard !isClosed else { throw QuickJsRuntimeError.closed }
        try resetIfRequired()
        guard handle != 0 else { throw QuickJsRuntimeError.closed }
        let status = tsuyomi_qjs_prepare_operation(handle, Int32(limits.maximumExecutionWallTimeMs))
        guard status == TSUYOMI_QJS_OK else { throw QuickJsRuntimeError.mapped(status) }
        activeOperation.withLock { $0 = handle }
        defer { activeOperation.withLock { $0 = 0 } }
        do {
            return try operation(handle)
        } catch let failure as QuickJsRuntimeError {
            if failure.invalidatesContext { discardContext() }
            throw failure
        }
    }

    private func resetIfRequired() throws {
        guard resetRequired else { return }
        let previous = handle
        handle = 0
        if previous != 0 { tsuyomi_qjs_close(previous) }
        guard !isClosed else { throw QuickJsRuntimeError.closed }
        let replacement = tsuyomi_qjs_create(limits.maximumMemoryBytes, QuickJsRuntimeLimits.stackSizeBytes)
        guard replacement != 0 else { throw QuickJsRuntimeError.nativeUnavailable }
        handle = replacement
        if let module = verifiedModule {
            let status = tsuyomi_qjs_prepare_operation(replacement, Int32(limits.maximumExecutionWallTimeMs))
            guard status == TSUYOMI_QJS_OK else {
                handle = 0
                tsuyomi_qjs_close(replacement)
                throw QuickJsRuntimeError.mapped(status)
            }
            do {
                try QuickJsRuntimeLane.evaluate(replacement, module)
            } catch {
                handle = 0
                tsuyomi_qjs_close(replacement)
                throw error
            }
        }
        resetRequired = false
    }

    private func discardContext() {
        resetRequired = true
        let previous = handle
        handle = 0
        if previous != 0 { tsuyomi_qjs_close(previous) }
    }

    private static func evaluate(_ handle: tsuyomi_qjs_handle, _ module: VerifiedModule) throws {
        let status = module.source.withUnsafeBytes { sourcePointer in
            module.filename.withUnsafeBytes { filenamePointer in
                tsuyomi_qjs_evaluate_module(
                    handle,
                    sourcePointer.bindMemory(to: UInt8.self).baseAddress,
                    module.source.count,
                    filenamePointer.bindMemory(to: UInt8.self).baseAddress,
                    module.filename.count
                )
            }
        }
        guard status == TSUYOMI_QJS_OK else { throw QuickJsRuntimeError.mapped(status) }
    }

    static func isModuleFilename(_ value: String) -> Bool {
        guard value.hasSuffix(".mjs"), !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "/" || scalar == "-"
        }
    }

    static func isFunctionName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...128).contains(scalars.count) else { return false }
        func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || scalar == "_" || scalar == "$"
        }
        guard isAlpha(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { isAlpha($0) || ("0"..."9").contains($0) }
    }
}
