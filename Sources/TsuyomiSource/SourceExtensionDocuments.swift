// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

extension SourceExtensionMarshalling {
    static func homePage(_ value: [String: JSONValue]) throws -> SourceHomePage {
        guard let schemaVersion = value.int("schemaVersion"), let title = value.string("title"),
              let rawFilters = value.array("filters"), let rawSelected = value.object("selectedFilters"),
              let rawSections = value.array("sections"), let complete = value.bool("complete") else {
            throw failure(.malformedSourceResponse, "home-parse", "invalid-home-page")
        }
        let filters = try rawFilters.map { element -> SourceHomeFilter in
            guard let filter = element.objectValue, let id = filter.string("id"),
                  let label = filter.string("label"), let options = filter.array("options") else {
                throw failure(.malformedSourceResponse, "home-parse", "invalid-home-filter")
            }
            return try SourceHomeFilter(
                id: id,
                label: label,
                options: try options.map { optionElement in
                    guard let option = optionElement.objectValue, let optionValue = option.string("value"),
                          let optionLabel = option.string("label") else {
                        throw failure(.malformedSourceResponse, "home-parse", "invalid-home-option")
                    }
                    return try SourceHomeFilterOption(value: optionValue, label: optionLabel)
                }
            )
        }
        let sections = try rawSections.map { element -> SourceHomeSection in
            guard let section = element.objectValue, let id = section.string("id"),
                  let sectionTitle = section.string("title"), let items = section.array("items") else {
                throw failure(.malformedSourceResponse, "home-parse", "invalid-home-section")
            }
            return try SourceHomeSection(
                id: id,
                title: sectionTitle,
                items: try items.map { item in
                    guard let object = item.objectValue else {
                        throw failure(.malformedSourceResponse, "home-parse", "invalid-item")
                    }
                    return try summary(object)
                }
            )
        }
        var features: [SourceHomeFeature] = []
        if let rawFeatures = value["features"], rawFeatures != .null {
            guard let items = rawFeatures.arrayValue else {
                throw failure(.malformedSourceResponse, "home-parse", "invalid-home-feature")
            }
            features = try items.map { element in
                guard let feature = element.objectValue, let id = feature.string("id"),
                      let featureTitle = feature.string("title"),
                      let selected = feature.object("selectedFilters") else {
                    throw failure(.malformedSourceResponse, "home-parse", "invalid-home-feature")
                }
                return try SourceHomeFeature(
                    id: id,
                    title: featureTitle,
                    supportingText: feature.string("supportingText"),
                    selectedFilters: selected.compactMapValues(\.stringValue)
                )
            }
        }
        do {
            return try SourceHomePage(
                title: title,
                schemaVersion: schemaVersion,
                filters: filters,
                selectedFilters: rawSelected.compactMapValues(\.stringValue),
                sections: sections,
                features: features,
                nextCursor: value.string("nextCursor"),
                complete: complete
            )
        } catch {
            throw failure(.malformedSourceResponse, "home-parse", "invalid-home-page")
        }
    }

    /// The host owns the content digest and the revision: an extension may not claim that changed
    /// text is the same revision, and it may not omit the identity the reader anchors to.
    static func document(_ value: [String: JSONValue]) throws -> ReaderDocument {
        guard let sourceId = value.string("sourceId"), let remoteBookId = value.string("remoteBookId"),
              let contentId = value.string("contentId"), let title = value.string("title"),
              let rawBlocks = value.array("blocks") else {
            throw failure(.malformedSourceResponse, "chapter-parse", "invalid-document")
        }
        let blocks = try rawBlocks.map { element -> ReaderBlock in
            guard let block = element.objectValue, let blockId = block.string("blockId"),
                  let kind = block.string("kind") else {
                throw failure(.malformedSourceResponse, "chapter-parse", "invalid-block")
            }
            return try readerBlock(kind: kind, blockId: blockId, block)
        }
        let contentDigest = ReaderDocument.contentDigest(of: blocks)
        do {
            return try ReaderDocument(
                kind: .chapter,
                identity: try DocumentIdentity(
                    sourceId: sourceId,
                    remoteBookId: remoteBookId,
                    contentId: contentId
                ),
                title: title,
                revision: value.string("revision") ?? contentDigest,
                contentDigest: contentDigest,
                blocks: blocks
            )
        } catch {
            throw failure(.malformedSourceResponse, "chapter-parse", "invalid-document")
        }
    }

    private static func readerBlock(
        kind: String,
        blockId: String,
        _ block: [String: JSONValue]
    ) throws -> ReaderBlock {
        switch kind {
        case "paragraph":
            guard let text = block.string("text") else {
                throw failure(.malformedSourceResponse, "chapter-parse", "invalid-block")
            }
            return .paragraph(try ReaderBlock.Paragraph(blockId: blockId, text: text))
        case "heading":
            guard let text = block.string("text"), let level = block.int("level") else {
                throw failure(.malformedSourceResponse, "chapter-parse", "invalid-block")
            }
            return .heading(try ReaderBlock.Heading(blockId: blockId, text: text, level: level))
        case "image":
            guard let url = block.string("url") else {
                throw failure(.malformedSourceResponse, "chapter-parse", "invalid-block")
            }
            var aspectRatio: Double?
            if let width = block.int("width"), let height = block.int("height"), width > 0, height > 0 {
                aspectRatio = min(Double(width) / Double(height), 100)
            }
            return .image(try ReaderBlock.Image(
                blockId: blockId,
                url: url,
                alternateText: block.string("altText"),
                aspectRatio: aspectRatio
            ))
        case "divider":
            return .divider(try ReaderBlock.Divider(blockId: blockId))
        case "quote":
            guard let text = block.string("text") else {
                throw failure(.malformedSourceResponse, "chapter-parse", "invalid-block")
            }
            return .quote(try ReaderBlock.Quote(
                blockId: blockId,
                text: text,
                attribution: block.string("attribution")
            ))
        default:
            throw failure(.malformedSourceResponse, "chapter-parse", "unsupported-block")
        }
    }
}
