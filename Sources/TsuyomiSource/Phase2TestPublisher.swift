// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG
import Foundation

/// The acceptance-fixture publisher. It is compiled only into DEBUG builds so a release host can
/// never trust a package signed with the published fixture key.
public enum Phase2TestPublisher {
    public static let keyId = "tsuyomi-phase2-fixture"
    public static let publicKeyHex = "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"

    public static func key() throws -> PublisherKey {
        guard let publicKey = Data(hex: publicKeyHex) else { throw HxpVerificationError.invalidManifest }
        return try PublisherKey(keyId: keyId, publicKey: publicKey, trust: .builtInTest)
    }
}
#endif

extension Data {
    init?(hex: String) {
        let scalars = Array(hex.utf8)
        guard scalars.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = Data.nibble(scalars[index]), let low = Data.nibble(scalars[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = bytes
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
