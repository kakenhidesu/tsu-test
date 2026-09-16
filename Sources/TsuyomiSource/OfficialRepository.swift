// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The catalog this app ships pointed at, and the two keys that anchor it. The root key is the only
/// thing that makes that catalog trustworthy — changing it here changes which catalogs the app
/// accepts — and the publisher key is what the packages it lists are signed with. Both are the values
/// configured in the `tsuyomi-extensions` official-distribution environment.
public enum OfficialRepository {
    public static let repositoryId = "org.tsuyomi.extensions"
    public static let indexUrl = "https://raw.githubusercontent.com/Chachaanteng/tsuyomi-extensions/repository/index-v1.json"
    public static let rootKeyId = "tsuyomi-repository-root-v1"
    public static let rootPublicKey = "SiFmEcSuYllT6mWoYOGykPBxPu/2W2ueRGUCjE2ufdI="
    public static let publisherKeyId = "tsuyomi-official-publisher-v1"
    public static let publisherPublicKey = "3bdE5VGvcQFSZ/XOTkphTTxVNQ2IC1QOSAouWS0oawA="

    public static func isRoot(_ publicKey: Data) -> Bool {
        (try? ExtensionRepositoryClient.rootKey(rootPublicKey)) == publicKey
    }

    public static func descriptor(addedAt: Date) throws -> RepositoryDescriptor {
        RepositoryDescriptor(
            repositoryId: repositoryId,
            indexUrl: try ExtensionRepositoryClient.normalize(indexUrl: indexUrl),
            rootKeyId: rootKeyId,
            rootPublicKey: try ExtensionRepositoryClient.rootKey(rootPublicKey),
            addedAt: addedAt
        )
    }

    public static func publisher(approvedAt: Date) throws -> TrustedPublisher {
        TrustedPublisher(
            keyId: publisherKeyId,
            publicKey: try ExtensionRepositoryClient.rootKey(publisherPublicKey),
            trust: .builtInOfficial,
            repositoryId: repositoryId,
            approvedAt: approvedAt
        )
    }
}
