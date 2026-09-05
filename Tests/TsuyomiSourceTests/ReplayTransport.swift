// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore

/// Every source test runs against this transport; no test may reach a real site.
actor RecordingTransport: HostHttpTransport {
    private var recorded: [HostHttpRequest] = []
    private let responder: @Sendable (HostHttpRequest) throws -> HostHttpResponse

    init(responder: @escaping @Sendable (HostHttpRequest) throws -> HostHttpResponse) {
        self.responder = responder
    }

    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        recorded.append(request)
        return try responder(request)
    }

    func requests() -> [HostHttpRequest] { recorded }
}
