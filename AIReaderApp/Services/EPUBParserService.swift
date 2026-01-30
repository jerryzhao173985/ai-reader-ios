// EPUBParserService.swift
// Service for parsing EPUB files into BookModel
//
// Uses native Swift libraries to extract metadata, chapters, TOC, and images

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZipArchive  // For EPUB extraction (EPUB is a ZIP file)

/// Service responsible for parsing EPUB files
@Observable
final class EPUBParserService {
    // MARK: - Errors
    enum EPUBError: LocalizedError {
        case fileNotFound
        case invalidEPUB
        case extractionFailed
        case parsingFailed(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "EPUB file not found"
            case .invalidEPUB:
                return "Invalid EPUB format"
            case .extractionFailed:
                return "Failed to extract EPUB contents"
            case .parsingFailed(let detail):
                return "Parsing failed: \(detail)"
            case .noContent:
                return "No readable content found in EPUB"
            }
        }
    }

    // MARK: - Properties
    private let fileManager = FileManager.default
    private let booksDirectory: URL

    // MARK: - Initialization
    init() {
        // Create books directory in app's documents folder
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectory = documentsPath.appendingPathComponent("Books", isDirectory: true)

        try? fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API
    /// Parse an EPUB file and create a BookModel
    func parseEPUB(at url: URL) async throws -> BookModel {
        // Ensure we can access the file
        guard url.startAccessingSecurityScopedResource() else {
            // Try without security scope for local files
            guard fileManager.fileExists(atPath: url.path) else {
                throw EPUBError.fileNotFound
            }
            return try await performParsing(url: url)
        }
        defer { url.stopAccessingSecurityScopedResource() }

        return try await performParsing(url: url)
    }

    // MARK: - Private Implementation
    private func performParsing(url: URL) async throws -> BookModel {
        // Create unique directory for this book
        let bookId = UUID()
        let bookDirectory = booksDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)

        // Copy EPUB to our storage
        let epubPath = bookDirectory.appendingPathComponent("original.epub")
        try fileManager.copyItem(at: url, to: epubPath)

        // Extract EPUB (it's a ZIP file)
        let extractedPath = bookDirectory.appendingPathComponent("extracted", isDirectory: true)
        try extractEPUB(from: epubPath, to: extractedPath)

        // Parse container.xml to find OPF file
        let opfPath = try findOPFFile(in: extractedPath)

        // Parse OPF for metadata and spine
        let (metadata, manifest, spine) = try parseOPF(at: opfPath)

        // Extract chapters from spine
        let chapters = try parseChapters(spine: spine, manifest: manifest, opfDirectory: opfPath.deletingLastPathComponent())

        // Parse TOC
        let toc = try parseTOC(manifest: manifest, opfDirectory: opfPath.deletingLastPathComponent())

        // Extract cover image
        let coverData = extractCoverImage(manifest: manifest, opfDirectory: opfPath.deletingLastPathComponent())

        // Create BookModel
        let book = BookModel(
            id: bookId,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            authors: metadata.authors,
            language: metadata.language,
            bookDescription: metadata.description,
            publisher: metadata.publisher,
            publishDate: metadata.date,
            subjects: metadata.subjects,
            identifiers: metadata.identifiers,
            coverImageData: coverData,
            sourceFilePath: url.path
        )

        // Add chapters
        for chapter in chapters {
            chapter.book = book
            book.chapters.append(chapter)
        }

        // Add TOC entries
        for entry in toc {
            entry.book = book
            book.tableOfContents.append(entry)
        }

        return book
    }

    // MARK: - EPUB Extraction
    private func extractEPUB(from source: URL, to destination: URL) throws {
        // EPUB is a ZIP file - use SSZipArchive or native unzipping
        let success = SSZipArchive.unzipFile(
            atPath: source.path,
            toDestination: destination.path
        )

        if !success {
            throw EPUBError.extractionFailed
        }
    }

    // MARK: - Container Parsing
    private func findOPFFile(in extractedPath: URL) throws -> URL {
        let containerPath = extractedPath
            .appendingPathComponent("META-INF")
            .appendingPathComponent("container.xml")

        guard fileManager.fileExists(atPath: containerPath.path) else {
            throw EPUBError.invalidEPUB
        }

        let containerData = try Data(contentsOf: containerPath)
        let containerXML = String(data: containerData, encoding: .utf8) ?? ""

        // Parse full-path from container.xml
        // Looking for: <rootfile full-path="..." media-type="application/oebps-package+xml"/>
        guard let range = containerXML.range(of: "full-path=\"([^\"]+)\"", options: .regularExpression),
              let pathRange = containerXML.range(of: "\"([^\"]+)\"", options: .regularExpression, range: range) else {
            throw EPUBError.parsingFailed("Could not find OPF path in container.xml")
        }

        var opfRelativePath = String(containerXML[pathRange])
        opfRelativePath = opfRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        let opfURL = extractedPath.appendingPathComponent(opfRelativePath)
        guard fileManager.fileExists(atPath: opfURL.path) else {
            throw EPUBError.parsingFailed("OPF file not found at \(opfRelativePath)")
        }

        return opfURL
    }

    // MARK: - OPF Parsing
    /// Sendable: Contains only value types, safe to pass across isolation boundaries
    struct EPUBMetadata: Sendable {
        var title: String?
        var authors: [String] = []
        var language: String?
        var description: String?
        var publisher: String?
        var date: String?
        var subjects: [String] = []
        var identifiers: [String: String] = [:]
    }

    /// Sendable: Contains only value types, safe to pass across isolation boundaries
    struct ManifestItem: Sendable {
        let id: String
        let href: String
        let mediaType: String
        var properties: String?
    }

    /// Sendable: Contains only value types, safe to pass across isolation boundaries
    struct SpineItem: Sendable {
        let idref: String
        var linear: Bool = true
    }

    private func parseOPF(at url: URL) throws -> (EPUBMetadata, [String: ManifestItem], [SpineItem]) {
        let data = try Data(contentsOf: url)
        let xmlString = String(data: data, encoding: .utf8) ?? ""

        var metadata = EPUBMetadata()
        var manifest: [String: ManifestItem] = [:]
        var spine: [SpineItem] = []

        // Parse metadata
        metadata.title = extractXMLValue(from: xmlString, tag: "dc:title")
            ?? extractXMLValue(from: xmlString, tag: "title")

        // Parse all creators/authors
        let authorPattern = "<dc:creator[^>]*>([^<]+)</dc:creator>"
        if let regex = try? NSRegularExpression(pattern: authorPattern, options: []) {
            let results = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in results {
                if let range = Range(match.range(at: 1), in: xmlString) {
                    metadata.authors.append(String(xmlString[range]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        metadata.language = extractXMLValue(from: xmlString, tag: "dc:language")
        metadata.description = extractXMLValue(from: xmlString, tag: "dc:description")
        metadata.publisher = extractXMLValue(from: xmlString, tag: "dc:publisher")
        metadata.date = extractXMLValue(from: xmlString, tag: "dc:date")

        // Parse subjects
        let subjectPattern = "<dc:subject[^>]*>([^<]+)</dc:subject>"
        if let regex = try? NSRegularExpression(pattern: subjectPattern, options: []) {
            let results = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in results {
                if let range = Range(match.range(at: 1), in: xmlString) {
                    metadata.subjects.append(String(xmlString[range]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        // Parse manifest items - match entire <item.../> elements, then extract attributes
        let manifestItemPattern = "<item\\s+[^>]+/>"
        if let itemRegex = try? NSRegularExpression(pattern: manifestItemPattern, options: []) {
            let results = itemRegex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in results {
                if let range = Range(match.range, in: xmlString) {
                    let itemElement = String(xmlString[range])

                    // Extract each attribute separately (handles any order)
                    let idValue = extractAttribute(from: itemElement, name: "id")
                    let hrefValue = extractAttribute(from: itemElement, name: "href")
                    let mediaTypeValue = extractAttribute(from: itemElement, name: "media-type")

                    if let id = idValue, let href = hrefValue, let mediaType = mediaTypeValue {
                        let decodedHref = href.removingPercentEncoding ?? href
                        manifest[id] = ManifestItem(id: id, href: decodedHref, mediaType: mediaType)
                    }
                }
            }
        }

        // Parse spine - match <itemref.../> elements
        let spineItemPattern = "<itemref\\s+[^>]+/>"
        if let itemRefRegex = try? NSRegularExpression(pattern: spineItemPattern, options: []) {
            let results = itemRefRegex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in results {
                if let range = Range(match.range, in: xmlString) {
                    let itemRefElement = String(xmlString[range])
                    if let idref = extractAttribute(from: itemRefElement, name: "idref") {
                        spine.append(SpineItem(idref: idref))
                    }
                }
            }
        }

        return (metadata, manifest, spine)
    }

    private func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]*)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        let value = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func extractAttribute(from element: String, name: String) -> String? {
        // Pattern matches: name="value" or name='value'
        let pattern = "\(name)=[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)),
              let range = Range(match.range(at: 1), in: element) else {
            return nil
        }
        return String(element[range])
    }

    // MARK: - Chapter Parsing
    private func parseChapters(spine: [SpineItem], manifest: [String: ManifestItem], opfDirectory: URL) throws -> [ChapterModel] {
        var chapters: [ChapterModel] = []

        for (index, spineItem) in spine.enumerated() {
            guard let manifestItem = manifest[spineItem.idref],
                  manifestItem.mediaType.contains("html") || manifestItem.mediaType.contains("xml") else {
                continue
            }

            let chapterURL = opfDirectory.appendingPathComponent(manifestItem.href)
            guard fileManager.fileExists(atPath: chapterURL.path) else {
                continue
            }

            let htmlData = try Data(contentsOf: chapterURL)
            let htmlContent = String(data: htmlData, encoding: .utf8) ?? ""

            #if DEBUG
            print("[EPUBParser] Chapter \(index + 1) - Raw file size: \(htmlData.count) bytes")
            print("[EPUBParser] Chapter \(index + 1) - Raw HTML length: \(htmlContent.count)")
            #endif

            // Extract plain text from HTML
            let plainText = extractPlainText(from: htmlContent)

            // Sanitize HTML for display
            let sanitizedHTML = sanitizeHTML(htmlContent)

            #if DEBUG
            print("[EPUBParser] Chapter \(index + 1) - Sanitized HTML length: \(sanitizedHTML.count)")
            print("[EPUBParser] Chapter \(index + 1) - Plain text length: \(plainText.count)")
            #endif

            // Get chapter title from HTML or use default
            let title = extractHTMLTitle(from: htmlContent) ?? "Chapter \(index + 1)"

            let chapter = ChapterModel(
                chapterId: manifestItem.id,
                href: manifestItem.href,
                title: title,
                htmlContent: sanitizedHTML,
                plainText: plainText,
                order: index
            )

            chapters.append(chapter)
        }

        guard !chapters.isEmpty else {
            throw EPUBError.noContent
        }

        return chapters
    }

    // MARK: - HTML Processing
    private func extractPlainText(from html: String) -> String {
        // Remove HTML tags and clean up whitespace
        var text = html

        // Remove script and style blocks entirely
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)

        // Replace common block elements with newlines
        text = text.replacingOccurrences(of: "</p>", with: "\n\n")
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</div>", with: "\n")

        // Remove all remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode HTML entities
        text = decodeHTMLEntities(text)

        // Clean up whitespace
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    private func sanitizeHTML(_ html: String) -> String {
        var sanitized = html

        // Remove potentially dangerous elements
        let removePatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<form[^>]*>[\\s\\S]*?</form>",
            "<input[^>]*>",
            "<button[^>]*>[\\s\\S]*?</button>",
            "<!--[\\s\\S]*?-->"
        ]

        for pattern in removePatterns {
            sanitized = sanitized.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // Extract only the body content from full XHTML documents
        // EPUB chapters are complete XHTML files, but we only need the body content
        sanitized = extractBodyContent(from: sanitized)

        return sanitized
    }

    /// Extracts the inner content of the <body> tag from an HTML document
    /// If no body tag is found, returns the original content
    private func extractBodyContent(from html: String) -> String {
        // Try to match <body...>content</body>
        let bodyPattern = "<body[^>]*>([\\s\\S]*)</body>"
        if let regex = try? NSRegularExpression(pattern: bodyPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: try to remove doctype, html, head tags if body extraction failed
        var cleaned = html
        // Remove DOCTYPE
        cleaned = cleaned.replacingOccurrences(of: "<!DOCTYPE[^>]*>", with: "", options: .regularExpression)
        // Remove xml declaration
        cleaned = cleaned.replacingOccurrences(of: "<\\?xml[^>]*\\?>", with: "", options: .regularExpression)
        // Remove html tags
        cleaned = cleaned.replacingOccurrences(of: "<html[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: "</html>", with: "", options: .caseInsensitive)
        // Remove head section
        cleaned = cleaned.replacingOccurrences(of: "<head[^>]*>[\\s\\S]*?</head>", with: "", options: [.regularExpression, .caseInsensitive])
        // Remove body tags (keep content)
        cleaned = cleaned.replacingOccurrences(of: "<body[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: "</body>", with: "", options: .caseInsensitive)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractHTMLTitle(from html: String) -> String? {
        // Method 1: Look for h1 with class="chapter-title" specifically (common in professionally formatted EPUBs)
        // This contains the descriptive chapter name like "CONTROL AND OUR UPBRINGING"
        let chapterTitlePattern = "<h1[^>]*class=\"[^\"]*chapter-title[^\"]*\"[^>]*>([\\s\\S]*?)</h1>"
        var descriptiveTitle: String?
        if let regex = try? NSRegularExpression(pattern: chapterTitlePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var content = String(html[range])
            content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                descriptiveTitle = decodeHTMLEntities(content)
            }
        }

        // Method 2: Look for h1 with class="chapter-number" for "Chapter X" format
        let chapterNumberPattern = "<h1[^>]*class=\"[^\"]*chapter-number[^\"]*\"[^>]*>([\\s\\S]*?)</h1>"
        var chapterNumber: String?
        if let regex = try? NSRegularExpression(pattern: chapterNumberPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var content = String(html[range])
            content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                chapterNumber = decodeHTMLEntities(content)
            }
        }

        // Combine chapter number and title if both exist (e.g., "Chapter 1: CONTROL AND OUR UPBRINGING")
        if let number = chapterNumber, let title = descriptiveTitle {
            return "\(number): \(title)"
        } else if let title = descriptiveTitle {
            return title
        } else if let number = chapterNumber {
            return number
        }

        // Method 3: Look for any h1 with class containing "chapter" as fallback
        let h1ChapterPattern = "<h1[^>]*class=\"[^\"]*chapter[^\"]*\"[^>]*>([\\s\\S]*?)</h1>"
        if let regex = try? NSRegularExpression(pattern: h1ChapterPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var content = String(html[range])
            content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                return decodeHTMLEntities(content)
            }
        }

        // Method 4: Try any h1 tag (skip title tags as they often contain book title)
        let anyH1Pattern = "<h1[^>]*>([\\s\\S]*?)</h1>"
        if let regex = try? NSRegularExpression(pattern: anyH1Pattern, options: []),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var content = String(html[range])
            content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                return decodeHTMLEntities(content)
            }
        }

        // Method 5: Try h2 tag
        let h2Pattern = "<h2[^>]*>([\\s\\S]*?)</h2>"
        if let regex = try? NSRegularExpression(pattern: h2Pattern, options: []),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var content = String(html[range])
            content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                return decodeHTMLEntities(content)
            }
        }

        return nil
    }

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
            "&ndash;": "–",
            "&mdash;": "—",
            "&lsquo;": "'",
            "&rsquo;": "'",
            "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}",
            "&hellip;": "…"
        ]

        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        // Handle numeric entities
        result = result.replacingOccurrences(
            of: "&#([0-9]+);",
            with: "",
            options: .regularExpression
        )

        return result
    }

    // MARK: - TOC Parsing
    private func parseTOC(manifest: [String: ManifestItem], opfDirectory: URL) throws -> [TOCEntryModel] {
        // Look for NCX file (EPUB 2) or nav document (EPUB 3)
        var tocEntries: [TOCEntryModel] = []

        // Try NCX first
        if let ncxItem = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let ncxURL = opfDirectory.appendingPathComponent(ncxItem.href)
            if fileManager.fileExists(atPath: ncxURL.path) {
                tocEntries = try parseNCX(at: ncxURL)
            }
        }

        // Try EPUB 3 nav if no NCX entries
        if tocEntries.isEmpty,
           let navItem = manifest.values.first(where: { $0.properties?.contains("nav") == true }) {
            let navURL = opfDirectory.appendingPathComponent(navItem.href)
            if fileManager.fileExists(atPath: navURL.path) {
                tocEntries = try parseNavDocument(at: navURL)
            }
        }

        return tocEntries
    }

    private func parseNCX(at url: URL) throws -> [TOCEntryModel] {
        let data = try Data(contentsOf: url)
        let xmlString = String(data: data, encoding: .utf8) ?? ""

        var entries: [TOCEntryModel] = []

        // Parse navPoint elements
        let navPointPattern = "<navPoint[^>]*>[\\s\\S]*?<navLabel>[\\s\\S]*?<text>([^<]*)</text>[\\s\\S]*?<content[^>]+src=\"([^\"]+)\"[^>]*/>[\\s\\S]*?</navPoint>"

        if let regex = try? NSRegularExpression(pattern: navPointPattern, options: []) {
            let results = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))

            for (index, match) in results.enumerated() {
                if let titleRange = Range(match.range(at: 1), in: xmlString),
                   let hrefRange = Range(match.range(at: 2), in: xmlString) {
                    let title = decodeHTMLEntities(String(xmlString[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines))
                    let href = String(xmlString[hrefRange])

                    entries.append(TOCEntryModel(
                        title: title,
                        href: href,
                        order: index
                    ))
                }
            }
        }

        return entries
    }

    private func parseNavDocument(at url: URL) throws -> [TOCEntryModel] {
        let data = try Data(contentsOf: url)
        let htmlString = String(data: data, encoding: .utf8) ?? ""

        var entries: [TOCEntryModel] = []

        // Parse nav > ol > li > a elements
        let linkPattern = "<a[^>]+href=\"([^\"]+)\"[^>]*>([^<]+)</a>"

        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let results = regex.matches(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString))

            for (index, match) in results.enumerated() {
                if let hrefRange = Range(match.range(at: 1), in: htmlString),
                   let titleRange = Range(match.range(at: 2), in: htmlString) {
                    let href = String(htmlString[hrefRange])
                    let title = decodeHTMLEntities(String(htmlString[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines))

                    entries.append(TOCEntryModel(
                        title: title,
                        href: href,
                        order: index
                    ))
                }
            }
        }

        return entries
    }

    // MARK: - Cover Image Extraction
    private func extractCoverImage(manifest: [String: ManifestItem], opfDirectory: URL) -> Data? {
        // Method 1: Look for item with cover properties
        if let coverItem = manifest.values.first(where: { $0.properties?.contains("cover-image") == true }) {
            let coverURL = opfDirectory.appendingPathComponent(coverItem.href)
            return try? Data(contentsOf: coverURL)
        }

        // Method 2: Look for item with "cover" in ID
        if let coverItem = manifest.values.first(where: {
            $0.id.lowercased().contains("cover") && $0.mediaType.starts(with: "image/")
        }) {
            let coverURL = opfDirectory.appendingPathComponent(coverItem.href)
            return try? Data(contentsOf: coverURL)
        }

        // Method 3: Look for image with "cover" in filename
        if let coverItem = manifest.values.first(where: {
            $0.href.lowercased().contains("cover") && $0.mediaType.starts(with: "image/")
        }) {
            let coverURL = opfDirectory.appendingPathComponent(coverItem.href)
            return try? Data(contentsOf: coverURL)
        }

        // Method 4: Use first image > 10KB
        for item in manifest.values where item.mediaType.starts(with: "image/") {
            let imageURL = opfDirectory.appendingPathComponent(item.href)
            if let data = try? Data(contentsOf: imageURL), data.count > 10_000 {
                return data
            }
        }

        return nil
    }
}
