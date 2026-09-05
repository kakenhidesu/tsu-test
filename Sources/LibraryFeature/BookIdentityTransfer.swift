// SPDX-License-Identifier: AGPL-3.0-only

import CoreTransferable
import Foundation
import TsuyomiProtocol
import UniformTypeIdentifiers

/// What a shelf drag carries. Only the book's identity travels; no cover bytes, no source response,
/// and nothing that another app could read as content.
public struct BookIdentityTransfer: Codable, Hashable, Sendable, Transferable {
    public let sourceId: String
    public let remoteBookId: String

    public init(identity: BookIdentity) {
        sourceId = identity.sourceId
        remoteBookId = identity.remoteBookId
    }

    public var identity: BookIdentity {
        get throws { try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId) }
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tsuyomiBookIdentity)
    }
}

extension UTType {
    static let tsuyomiBookIdentity = UTType(exportedAs: "org.tsuyomi.ios.book-identity")
}
