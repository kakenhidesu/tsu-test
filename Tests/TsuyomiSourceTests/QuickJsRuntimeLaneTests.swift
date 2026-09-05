// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import TsuyomiSource

final class QuickJsRuntimeLaneTests: XCTestCase {
    private func lane(wallTimeMs: Int = 2_000, memoryBytes: Int64 = 8 * 1024 * 1024) throws -> QuickJsRuntimeLane {
        try QuickJsRuntimeLane(
            limits: try QuickJsRuntimeLimits(
                maximumMemoryBytes: memoryBytes,
                maximumExecutionWallTimeMs: wallTimeMs
            )
        )
    }

    private func evaluate(_ lane: QuickJsRuntimeLane, _ source: String) async throws {
        try await lane.evaluateModule(source: Data(source.utf8), filename: "index.mjs")
    }

    func testModuleEvaluationAndJsonCall() async throws {
        let lane = try lane()
        try await evaluate(lane, """
        globalThis.tsuyomiExtension = {
          echo(value, times) { return { value, times, ok: true }; }
        };
        """)
        let result = try await lane.callJson(functionName: "echo", argumentsJson: "[\"a\",2]")
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["value"] as? String, "a")
        XCTAssertEqual(decoded["times"] as? Int, 2)
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        await lane.close()
    }

    func testImportIsRefusedByTheModuleLoader() async throws {
        let lane = try lane()
        do {
            try await evaluate(lane, "import fs from 'node:fs';\nglobalThis.tsuyomiExtension = {};")
            XCTFail("expected the import to be refused")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertTrue([.jsException, .nativeUnavailable].contains(failure) || failure == .memoryLimit)
        }
        await lane.close()
    }

    func testInfiniteLoopIsInterruptedAndTheContextIsRebuilt() async throws {
        let lane = try lane(wallTimeMs: 300)
        try await evaluate(lane, """
        globalThis.tsuyomiExtension = {
          spin() { while (true) {} },
          ping() { return "pong"; }
        };
        """)
        let started = Date()
        do {
            _ = try await lane.callJson(functionName: "spin", argumentsJson: "[]")
            XCTFail("expected the wall-clock limit to interrupt the loop")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertEqual(failure, .executionLimit)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        // The discarded context is rebuilt from the saved verified module before the next call.
        let recovered = try await lane.callJson(functionName: "ping", argumentsJson: "[]")
        XCTAssertEqual(recovered, "\"pong\"")
        await lane.close()
    }

    func testMemoryPressureIsReportedAndRecoverable() async throws {
        let lane = try lane(memoryBytes: 1_048_576)
        try await evaluate(lane, """
        globalThis.tsuyomiExtension = {
          hog() { const parts = []; for (;;) { parts.push(new Array(10000).fill('x')); } },
          ping() { return "pong"; }
        };
        """)
        do {
            _ = try await lane.callJson(functionName: "hog", argumentsJson: "[]")
            XCTFail("expected the memory limit to stop the allocation")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertTrue([.memoryLimit, .executionLimit].contains(failure))
        }
        let recovered = try await lane.callJson(functionName: "ping", argumentsJson: "[]")
        XCTAssertEqual(recovered, "\"pong\"")
        await lane.close()
    }

    func testDeepRecursionIsBoundedByTheStackLimit() async throws {
        let lane = try lane()
        try await evaluate(lane, """
        globalThis.tsuyomiExtension = {
          deep(n) { return this.deep(n + 1); },
          ping() { return "pong"; }
        };
        """)
        do {
            _ = try await lane.callJson(functionName: "deep", argumentsJson: "[0]")
            XCTFail("expected the stack bound to stop the recursion")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertEqual(failure, .jsException)
        }
        let recovered = try await lane.callJson(functionName: "ping", argumentsJson: "[]")
        XCTAssertEqual(recovered, "\"pong\"")
        await lane.close()
    }

    func testNonJsonResultAndMissingFunctionAreDistinctFailures() async throws {
        let lane = try lane()
        try await evaluate(lane, """
        globalThis.tsuyomiExtension = {
          cyclic() { const a = {}; a.self = a; return a; },
          undef() { return undefined; }
        };
        """)
        do {
            _ = try await lane.callJson(functionName: "undef", argumentsJson: "[]")
            XCTFail("expected a non-JSON result")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertEqual(failure, .nonJsonResult)
        }
        do {
            _ = try await lane.callJson(functionName: "absent", argumentsJson: "[]")
            XCTFail("expected a missing function")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertEqual(failure, .missingFunction)
        }
        do {
            _ = try await lane.callJson(functionName: "undef", argumentsJson: "{}")
            XCTFail("expected invalid arguments")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertEqual(failure, .invalidArguments)
        }
        await lane.close()
    }

    func testClosedLaneRefusesFurtherWork() async throws {
        let lane = try lane()
        try await evaluate(lane, "globalThis.tsuyomiExtension = { ping() { return 1; } };")
        await lane.close()
        do {
            _ = try await lane.callJson(functionName: "ping", argumentsJson: "[]")
            XCTFail("expected a closed lane to refuse work")
        } catch let failure as QuickJsRuntimeError {
            XCTAssertEqual(failure, .closed)
        }
    }

    func testFilenameAndFunctionNameGrammars() {
        XCTAssertTrue(QuickJsRuntimeLane.isModuleFilename("index.mjs"))
        XCTAssertTrue(QuickJsRuntimeLane.isModuleFilename("lib/index.mjs"))
        XCTAssertFalse(QuickJsRuntimeLane.isModuleFilename("index.js"))
        XCTAssertFalse(QuickJsRuntimeLane.isModuleFilename("../index.mjs".replacingOccurrences(of: ".", with: "·")))
        XCTAssertTrue(QuickJsRuntimeLane.isFunctionName("parseSearch"))
        XCTAssertTrue(QuickJsRuntimeLane.isFunctionName("$_a0"))
        XCTAssertFalse(QuickJsRuntimeLane.isFunctionName("0bad"))
        XCTAssertFalse(QuickJsRuntimeLane.isFunctionName(""))
    }
}
