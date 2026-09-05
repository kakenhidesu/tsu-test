// SPDX-License-Identifier: AGPL-3.0-only

public struct SourceBookDetail: Hashable, Sendable {
    public let summary: SourceBookSummary
    public let description: String?
    public let tags: [String]
    public let status: String?

    public init(summary: SourceBookSummary, description: String?, tags: [String], status: String?) throws {
        guard tags.count <= 128, tags.hasDistinctElements else { throw ProtocolError.invalidTags }
        if let description, Grammar.codePointCount(description) > 20_000 { throw ProtocolError.descriptionTooLong }
        self.summary = summary
        self.description = description
        self.tags = tags
        self.status = status
    }
}

public struct SourceChapter: Hashable, Sendable {
    public let chapterId: String
    public let title: String
    public let url: String
    public let volumeTitle: String?

    public init(chapterId: String, title: String, url: String, volumeTitle: String? = nil) throws {
        guard Grammar.hasCodePoints(chapterId, in: 1...256) else { throw ProtocolError.invalidChapterId }
        guard Grammar.hasCodePoints(title, in: 1...512) else { throw ProtocolError.invalidChapterTitle }
        if let volumeTitle {
            guard volumeTitle.contains(where: { !$0.isWhitespace }), Grammar.codePointCount(volumeTitle) <= 512 else {
                throw ProtocolError.invalidVolumeTitle
            }
        }
        self.chapterId = chapterId
        self.title = title
        self.url = url
        self.volumeTitle = volumeTitle
    }
}

public struct SourceDirectory: Hashable, Sendable {
    public let bookIdentity: BookIdentity
    public let chapters: [SourceChapter]

    public init(bookIdentity: BookIdentity, chapters: [SourceChapter]) throws {
        guard !chapters.isEmpty else { throw ProtocolError.emptyDirectory }
        guard chapters.map(\.chapterId).hasDistinctElements else { throw ProtocolError.duplicateChapterIdentity }
        self.bookIdentity = bookIdentity
        self.chapters = chapters
    }
}
