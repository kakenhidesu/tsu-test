// SPDX-License-Identifier: AGPL-3.0-only

public enum ProtocolError: Error, Equatable, Sendable {
    case sourceIdGrammar
    case remoteIdCodePoints(field: String)
    case boundedText(field: String)
    case textAnchorDigest
    case negativeCharacterOffset
    case characterOffsetRequiresBlockId
    case textAnchorDigestRequiresBlockId
    case progressRange(field: String)
    case locatorAnchorMissing

    case invalidSourceId
    case originNotHttps
    case invalidHttpsOrigin
    case originContainsPath
    case originMissingHost
    case invalidOriginPort

    case invalidRequestUrl
    case tooManyRequestHeaders
    case invalidRequestHeader
    case requestBodyConflict
    case bodyRequiresPost
    case postMustBypassCache
    case postCannotCache
    case invalidSemanticCacheKey
    case invalidQuery
    case queryEncodingRequiresQuery
    case invalidFormField
    case invalidUtf8Body
    case invalidReferrerUrl

    case invalidHttpStatus
    case responseBodyRepresentation
    case invalidDiagnosticId
    case invalidResponseHeader
    case invalidRetryAfter

    case invalidCorrelationId
    case invalidDiagnostic
    case invalidRedirectCount

    case invalidBookTitle
    case invalidAuthor
    case invalidCanonicalUrl
    case invalidCoverUrl

    case invalidHomeFilterOption
    case invalidHomeFilterLabel
    case invalidHomeFilterId
    case invalidHomeFilterOptions
    case duplicateHomeFilterOption
    case invalidHomeFeatureId
    case invalidHomeFeatureTitle
    case invalidHomeFeatureSupportingText
    case invalidHomeFeatureSelection
    case invalidHomeSectionId
    case invalidHomeSectionTitle
    case invalidHomeSectionItems
    case invalidSourceHomeTitle
    case unsupportedSourceHomeSchemaVersion
    case invalidSourceHomeFilters
    case invalidSelectedHomeFilters
    case unknownSelectedHomeFilter
    case invalidSelectedHomeFilterOption
    case invalidSourceHomeSections
    case duplicateSourceHomeSection
    case invalidSourceHomeFeatures
    case sourceHomePageTooLarge
    case invalidSourceHomeCursor
    case incompleteSourceHomePageRequiresCursor

    case remotePageTooLarge
    case invalidRemoteCursor
    case incompletePageRequiresCursor

    case invalidTags
    case descriptionTooLong

    case invalidChapterId
    case invalidChapterTitle
    case invalidChapterUrl
    case invalidVolumeTitle
    case emptyDirectory
    case duplicateChapterIdentity

    case invalidBlockId
    case invalidParagraph
    case invalidHeading
    case invalidImageUrl
    case invalidImageAlternateText
    case invalidImageDimension
    case invalidQuoteText
    case invalidQuoteAttribution
    case invalidPostFloor
    case invalidPostBlocks
    case duplicatePostBlockIdentity

    case invalidContentId
    case invalidDocumentRevision
    case invalidDocumentTitle
    case invalidDocumentBlocks
    case duplicateBlockIdentity
    case invalidContentDigest
    case unknownBlockKind(String)
    case unknownDocumentKind(String)

    case invalidThreadId
    case invalidCatalogueEntries
    case invalidCatalogueEntryId
    case invalidCatalogueLabel
    case invalidPhysicalPage
    case invalidCatalogueOrder
    case duplicateCatalogueEntry
    case invalidOwnerCatalogueEntries
    case invalidSourceFingerprint
    case unknownSelectionRole(String)
    case unknownNavigationKind(String)

    case invalidSmartRule(violations: [SmartRuleViolation])
    case invalidSmartRuleVersion

    case duplicateBookIdentity
    case duplicateShelfIdentity
    case shelfParentCycle

    case invalidTimestamp(field: String)
    case malformedJson
    case unexpectedJsonType(field: String)
    case unknownField(String)
    case missingField(String)
}
