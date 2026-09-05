// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ImageIO
import TsuyomiProtocol
import UIKit

/// Decodes one cover at a time per source partition, never above the size actually displayed, and
/// caches the encoded bytes under a digest of the source, package, and credential revision.
public actor HostCoverLoader {
    static let maximumSourcePixels = 50_000_000
    static let defaultMaximumResponseBytes = 8 * 1024 * 1024
    static let supportedContentTypes: Set<String> = ["image/jpeg", "image/png"]

    private let policy: MediaOriginPolicy
    private let files: QuotaFileStore
    private let fetcher: any CoverMediaFetcher
    private let maximumResponseBytes: Int
    private var decoded: [String: UIImage] = [:]
    private var decodedOrder: [String] = []
    private let decodedCapacity = 64

    public init(
        policy: MediaOriginPolicy,
        files: QuotaFileStore,
        fetcher: any CoverMediaFetcher,
        maximumResponseBytes: Int = HostCoverLoader.defaultMaximumResponseBytes
    ) {
        self.policy = policy
        self.files = files
        self.fetcher = fetcher
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func load(
        url: String,
        referrerUrl: String?,
        targetWidthPx: Int,
        targetHeightPx: Int
    ) async throws -> UIImage {
        let allowed = try policy.requireAllowed(url)
        let key = Sha256.hex("\(allowed)\u{0}\(targetWidthPx)x\(targetHeightPx)")
        if let cached = decoded[key] { return cached }
        let encoded = try await encodedBytes(allowed, referrerUrl: referrerUrl, key: key)
        let image = try decode(encoded, targetWidthPx: targetWidthPx, targetHeightPx: targetHeightPx)
        remember(key, image)
        return image
    }

    private func encodedBytes(_ url: String, referrerUrl: String?, key: String) async throws -> Data {
        let path = "covers/\(key).bin"
        if let cached = try? await files.read(path), cached.count <= maximumResponseBytes { return cached }
        let payload: CoverMediaPayload
        do {
            payload = try await fetcher.fetch(url: url, referrerUrl: referrerUrl)
        } catch let failure as MediaLoadError {
            throw failure
        } catch {
            throw MediaLoadError.httpFailure
        }
        guard payload.bytes.count <= maximumResponseBytes else { throw MediaLoadError.responseTooLarge }
        guard HostCoverLoader.supportedContentTypes.contains(payload.contentType) else {
            throw MediaLoadError.unsupportedContent
        }
        _ = try? await files.write(path, bytes: payload.bytes)
        return payload.bytes
    }

    /// The pixel budget is checked from the image header before any full-size buffer is allocated,
    /// so an oversized remote image cannot exhaust memory before it is rejected.
    private func decode(_ bytes: Data, targetWidthPx: Int, targetHeightPx: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw MediaLoadError.decodeFailed
        }
        guard width * height <= HostCoverLoader.maximumSourcePixels else { throw MediaLoadError.responseTooLarge }
        let maximumPixel = max(targetWidthPx, targetHeightPx)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaLoadError.decodeFailed
        }
        return UIImage(cgImage: thumbnail)
    }

    private func remember(_ key: String, _ image: UIImage) {
        if decoded[key] == nil { decodedOrder.append(key) }
        decoded[key] = image
        while decodedOrder.count > decodedCapacity {
            let evicted = decodedOrder.removeFirst()
            decoded.removeValue(forKey: evicted)
        }
    }
}
