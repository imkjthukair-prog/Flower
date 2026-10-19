import Foundation
import AppKit
import PDFKit
import JavaScriptCore
import WebKit
import Security
import ImageIO
import UniformTypeIdentifiers

/// Independently written native adapter for the locally supplied conversion resources.
/// PagesWriter.js embeds cupertino-files (MIT; see CupertinoFiles-Licenses.txt).
/// OfficePreview.js embeds docx-preview/JSZip (see OfficePreview-Licenses.txt).
/// Their bridge contracts were inspected statically with REA; the supplied resources
/// and Tangerine Java helper remain unchanged. No purchase/licensing code is used here.
final class DocumentEngine {
    private let resources: URL
    init(resources: URL) { self.resources = resources }

    private static let documents: Set<String> = ["txt", "md", "markdown", "html", "htm", "rtf", "rtfd", "doc", "docx", "odt", "pages"]
    private static let spreadsheets: Set<String> = ["xls", "xlsx", "ods", "csv", "tsv", "tab"]
    private static let textTargets = ["txt", "md", "rtf", "docx", "html", "pdf", "pages", "epub"]

    static func targets(for ext: String) -> [String] {
        let source = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if documents.contains(source) { return textTargets.filter { $0 != source } }
        if spreadsheets.contains(source) { return ["xlsx", "ods", "csv", "tsv", "pdf"].filter { $0 != source } }
        if ["ppt", "pptx"].contains(source) { return ["pdf"] }
        if source == "pdf" { return ["txt", "md", "rtf", "docx", "html", "pages", "epub", "png", "jpg", "pptx", "xlsx"] }
        return []
    }

    static func canConvert(from: String, to: String) -> Bool {
        targets(for: from).contains(to.lowercased() == "jpeg" ? "jpg" : to.lowercased())
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }

    /// Output is a regular file, or a directory for multi-page images / multi-sheet CSV.
    /// A staging directory prevents failed conversions from leaving a partial destination.
    @MainActor
    func convert(source: URL, destination: URL, target: String) async throws {
        let input = source.pathExtension.lowercased()
        let output = target.lowercased() == "jpeg" ? "jpg" : target.lowercased()
        guard Self.canConvert(from: input, to: output) else {
            throw Failure.message("Conversion from \(input.uppercased()) to \(output.uppercased()) is not supported.")
        }
        let fm = FileManager.default
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw Failure.message("The output must be different from the source file.")
        }
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.message("The output already exists. Choose a new filename.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isRegularFile == true || (input == "rtfd" && values.isDirectory == true) else {
            throw Failure.message("Choose a document file. Folder-based Pages packages must be saved as a single Pages file first.")
        }
        guard (values.fileSize ?? 0) <= 134_217_728 else { throw Failure.message("Documents must be smaller than 128 MB.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".conversion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let result = staging.appendingPathComponent("result.\(output)")
        try Task.checkCancellation()

        if Self.spreadsheets.contains(input) || (input == "pdf" && output == "xlsx") {
            if input == "pdf" { _ = try pdfText(source) }
            try await java(className: "TangerineSpreadsheet", source: source, destination: result, target: output)
        } else if ["ppt", "pptx"].contains(input) || (input == "pdf" && output == "pptx") {
            try await java(className: "TangerinePowerPoint", source: source, destination: result, target: output)
        } else if input == "pdf" && ["png", "jpg"].contains(output) {
            try renderPDFImages(source: source, destination: result, format: output)
        } else if output == "pdf" && ["docx", "pages"].contains(input) {
            try await renderOfficePDF(source: source, destination: result)
        } else {
            let text: NSAttributedString
            if input == "pdf" { text = try pdfText(source) }
            else if input == "pages" { text = try pagesText(source, preserveLayout: !["txt", "md", "epub"].contains(output)) }
            else { text = try readText(source, format: input) }
            try Task.checkCancellation()
            switch output {
            case "txt": try plainText(text).write(to: result, atomically: true, encoding: .utf8)
            case "md": try markdown(text).write(to: result, atomically: true, encoding: .utf8)
            case "pages": try writePages(text, to: result)
            case "pdf": try renderTextPDF(text, to: result)
            case "epub": try await writeEPUB(plainText(text), title: source.deletingPathExtension().lastPathComponent, destination: result)
            case "rtf", "docx", "html":
                let type: NSAttributedString.DocumentType = output == "rtf" ? .rtf : output == "docx" ? .officeOpenXML : .html
                var data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue])
                if output == "html", let html = String(data: data, encoding: .utf8) {
                    // AppKit emits a legacy remote DTD declaration. Our output
                    // needs no external DTD and should round-trip offline.
                    data = Data(html.replacingOccurrences(of: #"(?is)<!DOCTYPE[^>]*>"#, with: "<!DOCTYPE html>", options: .regularExpression).utf8)
                }
                try data.write(to: result, options: .atomic)
            default: throw Failure.message("This document output format is unavailable.")
            }
        }
        try Task.checkCancellation()
        guard fm.fileExists(atPath: result.path) else { throw Failure.message("The converter did not create an output.") }
        let finalValues = try result.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if finalValues.isDirectory != true && (finalValues.fileSize ?? 0) == 0 {
            throw Failure.message("The converter returned an empty output.")
        }
        // moveItem fails if another conversion has meanwhile claimed this filename.
        try fm.moveItem(at: result, to: destination)
    }

    // MARK: - Native document import/export

    @MainActor
    private func readText(_ url: URL, format: String) throws -> NSAttributedString {
        if ["txt", "md", "markdown"].contains(format) {
            let data = try Data(contentsOf: url)
            let plain: String
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let decoded = String(data: data, encoding: .utf16) { plain = decoded }
            else if let decoded = String(data: data, encoding: .utf8) { plain = decoded }
            else { throw Failure.message("This text file is not UTF-8 or BOM-marked UTF-16. Save it in UTF-8 first.") }
            if format != "txt" {
                return try readMarkdown(plain)
            }
            return NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        let type: NSAttributedString.DocumentType
        switch format {
        case "rtf": type = .rtf
        case "rtfd": type = .rtfd
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        case "html", "htm":
            let data = try Data(contentsOf: url)
            guard let html = String(data: data, encoding: .utf8) else { throw Failure.message("Save this HTML document as UTF-8 before converting it.") }
            return try readOfflineHTML(html)
        default: throw Failure.message("This document type cannot be read locally.")
        }
        return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    /// Text-only HTML import. Never pass untrusted HTML to AppKit/WebKit, whose
    /// importers can resolve resources before a URL-string filter sees them.
    /// All attributes and CSS are inert; rich styling/images are not retained.
    @MainActor
    private func readOfflineHTML(_ html: String) throws -> NSAttributedString {
        let resourceTags = #"(?is)<\s*/?\s*(?:img|script|link|iframe|frame|frameset|object|embed|video|audio|source|base|svg|math|input|applet)\b"#
        let declarations = #"(?is)<!\s*(?:ENTITY\b|DOCTYPE\b[^>]*(?:\bSYSTEM\b|\bPUBLIC\b|\[))"#
        if html.range(of: resourceTags, options: .regularExpression) != nil || html.range(of: declarations, options: .regularExpression) != nil {
            throw Failure.message("This HTML contains embedded resources or active content. Export a text-only HTML document first. HTML conversion preserves text and paragraph breaks, not styling or images.")
        }
        let tokenRegex = try NSRegularExpression(pattern: #"(?s)<!--.*?-->|<[^>]*>|[^<]+|<"#)
        let tagRegex = try NSRegularExpression(pattern: #"^<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)"#)
        let ns = html as NSString
        var output = ""
        var ignored: String?
        var preformatted = false
        let paragraphs: Set<String> = ["p", "div", "section", "article", "header", "footer", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table"]
        func lineBreak(_ count: Int) {
            output = output.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            if !output.isEmpty {
                let existing = output.reversed().prefix(while: { $0 == "\n" }).count
                if existing < count { output += String(repeating: "\n", count: count - existing) }
            }
        }
        for tokenMatch in tokenRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: tokenMatch.range)
            if token.hasPrefix("<") {
                let tokenNS = token as NSString
                guard let tag = tagRegex.firstMatch(in: token, range: NSRange(location: 0, length: tokenNS.length)) else { continue }
                let closing = tokenNS.substring(with: tag.range(at: 1)) == "/"
                let name = tokenNS.substring(with: tag.range(at: 2)).lowercased()
                if let hidden = ignored { if closing && name == hidden { ignored = nil }; continue }
                if !closing && ["head", "style", "noscript", "template"].contains(name) { ignored = name; continue }
                if name == "pre" { preformatted = !closing; lineBreak(2) }
                else if paragraphs.contains(name) { lineBreak(2) }
                else if ["br", "li", "tr", "hr"].contains(name) { lineBreak(1) }
                else if closing && ["td", "th"].contains(name) { output += "\t" }
                continue
            }
            guard ignored == nil else { continue }
            let decoded = try decodeHTMLEntities(token)
            if preformatted { output += decoded }
            else {
                var text = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                if output.isEmpty || output.last?.isWhitespace == true { text = text.replacingOccurrences(of: #"^ +"#, with: "", options: .regularExpression) }
                output += text
            }
        }
        let plain = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    private func decodeHTMLEntities(_ text: String) throws -> String {
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®", "bull": "•", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]
        let regex = try NSRegularExpression(pattern: #"&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let entity = ns.substring(with: match.range(at: 1))
            var replacement = names[entity]
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number), number != 0 { replacement = String(scalar) }
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }

    @MainActor
    private func readMarkdown(_ plain: String) throws -> NSAttributedString {
        // Parse inline CommonMark one line at a time. Foundation's full block parser
        // stores paragraph boundaries as presentation intents, which would otherwise
        // disappear when bridged to AppKit's attributed strings.
        let output = NSMutableAttributedString(string: "")
        var codeBlock = false
        let lines = plain.components(separatedBy: "\n")
        for (index, original) in lines.enumerated() {
            var line = original
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                codeBlock.toggle()
                if index + 1 < lines.count { output.append(NSAttributedString(string: "\n")) }
                continue
            }
            var size: CGFloat = 12
            var heading = false
            let hashes = line.prefix(while: { $0 == "#" }).count
            if !codeBlock && hashes > 0 && hashes <= 6 && line.dropFirst(hashes).hasPrefix(" ") {
                heading = true
                size = CGFloat(max(13, 27 - hashes * 3))
                line = String(line.dropFirst(hashes + 1))
            }
            if !codeBlock && (line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")) { line = "• " + line.dropFirst(2) }
            if codeBlock {
                output.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
            } else {
                let parsed = try AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                for run in parsed.runs {
                    let intent = run.inlinePresentationIntent
                    var font = intent?.contains(.code) == true ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
                    if heading || intent?.contains(.stronglyEmphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if intent?.contains(.emphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    var attributes: [NSAttributedString.Key: Any] = [.font: font]
                    if let link = run.link { attributes[.link] = link }
                    if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
                }
            }
            if index + 1 < lines.count { output.append(NSAttributedString(string: "\n")) }
        }
        return output
    }

    @MainActor
    private func pdfText(_ source: URL) throws -> NSAttributedString {
        guard let pdf = PDFDocument(url: source), !pdf.isLocked else { throw Failure.message("The PDF is unreadable or password protected.") }
        guard pdf.pageCount > 0 && pdf.pageCount <= 1000 else { throw Failure.message("The PDF must contain between 1 and 1,000 pages.") }
        let text = NSMutableAttributedString(string: "")
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            if let content = page.attributedString, !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text.append(content)
            } else if pageHasVisibleContent(page) {
                throw Failure.message("Page \(index + 1) has visible content but no selectable text. OCR is required before editable conversion; choose PNG, JPG or PowerPoint to preserve every page.")
            }
            if index + 1 < pdf.pageCount { text.append(NSAttributedString(string: "\n\n")) }
        }
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.message("This PDF has no selectable text. Scanned PDFs require OCR before text conversion.")
        }
        // PDF text extraction creates editable text; it is not a geometric reconstruction.
        return text
    }

    /// Distinguish truly blank pages from scans/outlines so a mixed PDF cannot
    /// silently lose an image-only page during text or editable export.
    private func pageHasVisibleContent(_ page: PDFPage) -> Bool {
        guard let pdfPage = page.pageRef else { return true }
        let side = 128
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(pdfPage)
            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if min(bytes[index], bytes[index + 1], bytes[index + 2]) < 245 { return true }
            }
            return false
        }
    }

    @MainActor
    private func renderTextPDF(_ text: NSAttributedString, to destination: URL) throws {
        let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        // System Arabic fallback currently embeds a variable SF font with an
        // unreliable PDF Unicode map. A synthetic probe verified that static
        // GeezaPro preserves both connected glyphs and the original Arabic text.
        // Keep explicitly chosen document fonts; normalize only system fallback.
        // Keep paragraph whitespace in the same font for coherent RTL layout.
        let arabic = try NSRegularExpression(pattern: #"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]+"#)
        var substitutions: [(NSRange, NSFont)] = []
        let nsText = storage.string as NSString
        let paragraphs = Set(arabic.matches(in: storage.string, range: NSRange(location: 0, length: storage.length)).map { nsText.paragraphRange(for: $0.range) })
        for paragraph in paragraphs {
            storage.enumerateAttribute(.font, in: paragraph) { value, range, _ in
                let font = value as? NSFont
                if font == nil || font!.fontName.hasPrefix(".") {
                    let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
                    if let replacement = NSFont(name: bold ? "GeezaPro-Bold" : "GeezaPro", size: font?.pointSize ?? 12) { substitutions.append((range, replacement)) }
                }
            }
        }
        for (range, font) in substitutions { storage.addAttribute(.font, value: font, range: range) }
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 54
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure.message("Could not initialize PDF output.") }
        var lastEnd = 0
        for _ in 0..<10_000 {
            let container = NSTextContainer(containerSize: CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0 && NSMaxRange(range) > lastEnd else { throw Failure.message("A document object is too large for a printable page.") }
            var bounds = CGRect(origin: .zero, size: pageSize)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.saveGState()
            context.translateBy(x: margin, y: pageSize.height - margin)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            // Direct NSLayoutManager.drawGlyphs writes visually ordered RTL runs
            // into PDFs. Native attributed drawing retains their logical Unicode
            // order; keep TextKit here only to determine each page's text range.
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            storage.attributedSubstring(from: characters).draw(in: CGRect(x: 0, y: 0, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            lastEnd = NSMaxRange(range)
            if lastEnd >= layout.numberOfGlyphs {
                context.closePDF()
                try (data as Data).write(to: destination, options: .atomic)
                return
            }
        }
        throw Failure.message("The document would produce more than 10,000 PDF pages.")
    }

    private func startsRightToLeft(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first(where: { $0.properties.isAlphabetic }) else { return false }
        return (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFDFF).contains(scalar.value) || (0xFE70...0xFEFF).contains(scalar.value)
    }

    private func plainText(_ text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{FFFC}", with: "[Image]")
    }

    private func markdown(_ text: NSAttributedString) -> String {
        // Plain paragraphs are valid Markdown. Escape syntax to preserve literal content.
        var result = plainText(text).replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "[", "]", "#", "<", ">", "`"] { result = result.replacingOccurrences(of: character, with: "\\" + character) }
        return result
    }

    // MARK: - Pages bridge

    @MainActor
    private func pagesContext() throws -> JSContext {
        guard let context = JSContext() else { throw Failure.message("The JavaScript document engine could not start.") }
        let random: @convention(block) (Int) -> [UInt8] = { count in
            guard count > 0 && count <= 1_048_576 else { return [] }
            var bytes = [UInt8](repeating: 0, count: count)
            let result = bytes.withUnsafeMutableBytes { raw in SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!) }
            return result == errSecSuccess ? bytes : []
        }
        context.setObject(random, forKeyedSubscript: "tangerineRandomBytes" as NSString)
        let script = try String(contentsOf: requiredResource("PagesWriter.js"), encoding: .utf8)
        context.evaluateScript(script)
        if let error = context.exception { throw Failure.message("Pages engine: \(error.toString() ?? "initialization failed")") }
        return context
    }

    @MainActor
    private func call(_ context: JSContext, _ function: String, _ arguments: [Any]) throws -> String {
        context.exception = nil
        guard let result = context.objectForKeyedSubscript(function)?.call(withArguments: arguments), !result.isUndefined else {
            throw Failure.message(context.exception?.toString() ?? "The Pages engine returned no result.")
        }
        if let exception = context.exception { throw Failure.message(exception.toString() ?? "Pages conversion failed.") }
        guard let string = result.toString() else { throw Failure.message("The Pages engine returned an invalid result.") }
        return string
    }

    @MainActor
    private func pagesModel(_ source: URL) throws -> [String: Any] {
        let context = try pagesContext()
        let json = try call(context, "readPages", [Data(contentsOf: source).base64EncodedString()])
        guard let data = json.data(using: .utf8), let model = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.message("The Pages document model could not be read.") }
        return model
    }

    @MainActor
    private func pagesText(_ source: URL, preserveLayout: Bool) throws -> NSAttributedString {
        let model = try pagesModel(source)
        let floating = model["floating"] as? [[String: Any]] ?? []
        if preserveLayout && ((model["pageLayout"] as? Bool == true) || floating.contains(where: { !($0["items"] as? [Any] ?? []).isEmpty })) {
            throw Failure.message("This Pages document contains positioned drawings. Choose PDF to preserve its layout, or TXT for extracted text.")
        }
        let sections = model["sections"] as? [[String: Any]] ?? []
        let headers = sections.flatMap { ($0["headers"] as? [[[String: Any]]] ?? []).flatMap { $0 } }
        let footers = sections.flatMap { ($0["footers"] as? [[[String: Any]]] ?? []).flatMap { $0 } }
        let notes = model["notes"] as? [[String: Any]] ?? []
        let hasHeaderFooter = (headers + footers).contains { paragraph in
            (paragraph["segments"] as? [[String: Any]] ?? []).contains { segment in
                segment["kind"] as? String != "text" || !(segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        if preserveLayout && (hasHeaderFooter || !notes.isEmpty) {
            throw Failure.message("This Pages document has headers, footers or footnotes. Choose PDF to preserve them, or TXT for extracted content.")
        }
        let assets = model["assets"] as? [[String: Any]] ?? []
        let output = NSMutableAttributedString(string: "")
        func paragraphs(_ values: [[String: Any]]) throws {
            for paragraph in values {
                var base = nativeAttributes(paragraph["formatting"] as? [String: Any] ?? [:])
                let paragraphStyle = (base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraphStyle.baseWritingDirection = paragraph["rtl"] as? Bool == true ? .rightToLeft : .leftToRight
                base[.paragraphStyle] = paragraphStyle
                for segment in paragraph["segments"] as? [[String: Any]] ?? [] {
                    switch segment["kind"] as? String ?? "text" {
                    case "text":
                        var attributes = base
                        let formatting = nativeAttributes(["character": segment["formatting"] as? [String: Any] ?? [:]])
                        attributes.merge(formatting) { _, new in new }
                        if let url = segment["url"] as? String { attributes[.link] = url }
                        output.append(NSAttributedString(string: segment["text"] as? String ?? "", attributes: attributes))
                    case "image":
                        if let index = segment["asset"] as? Int, assets.indices.contains(index), let encoded = assets[index]["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                            let attachment = NSTextAttachment()
                            let geometry = segment["geometry"] as? [String: Any] ?? [:]
                            image.size = NSSize(width: min(504, geometry["width"] as? Double ?? image.size.width), height: geometry["height"] as? Double ?? image.size.height)
                            attachment.image = image
                            output.append(NSAttributedString(attachment: attachment))
                        } else { throw Failure.message("A Pages image could not be decoded.") }
                    case "table":
                        // Text extraction keeps every cell; rich outputs refuse to silently flatten a table.
                        if preserveLayout { throw Failure.message("Export this Pages table as PDF, or choose TXT to extract its cells. Editable table reconstruction is not implemented in this local build.") }
                        for row in segment["rows"] as? [[[String: Any]]] ?? [] {
                            output.append(NSAttributedString(string: row.map { $0["text"] as? String ?? "" }.joined(separator: "\t") + "\n", attributes: base))
                        }
                    case "box": try paragraphs(segment["paragraphs"] as? [[String: Any]] ?? [])
                    case "toc":
                        for entry in segment["entries"] as? [[String: Any]] ?? [] { output.append(NSAttributedString(string: "\(entry["heading"] ?? "")\t\(entry["pageNumber"] ?? "")\n", attributes: base)) }
                    case "pageField":
                        if preserveLayout { throw Failure.message("This Pages document has dynamic page fields. Choose PDF to retain the correct page numbering.") }
                    default: throw Failure.message("A Pages text attachment is unsupported.")
                    }
                }
                output.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        if !preserveLayout { try paragraphs(headers) }
        try paragraphs(model["paragraphs"] as? [[String: Any]] ?? [])
        if !preserveLayout {
            for page in floating {
                for item in page["items"] as? [[String: Any]] ?? [] {
                    try paragraphs([["segments": [item]]])
                }
            }
            try paragraphs(footers)
        }
        for note in notes {
            output.append(NSAttributedString(string: "\n\(note["mark"] ?? "*") "))
            try paragraphs(note["paragraphs"] as? [[String: Any]] ?? [])
        }
        return output
    }

    @MainActor
    private func nativeAttributes(_ formatting: [String: Any]) -> [NSAttributedString.Key: Any] {
        let character = formatting["character"] as? [String: Any] ?? [:]
        var attributes: [NSAttributedString.Key: Any] = [:]
        let size = character["fontSize"] as? Double ?? 12
        var font = NSFont(name: character["fontName"] as? String ?? "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
        if character["bold"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if character["italic"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        if !character.isEmpty { attributes[.font] = font }
        if character["underline"] as? Bool == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if character["strikethru"] as? Bool == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let color = character["fontColor"] as? [String: Double] {
            attributes[.foregroundColor] = NSColor(calibratedRed: color["r"] ?? color["white"] ?? 0, green: color["g"] ?? color["white"] ?? 0, blue: color["b"] ?? color["white"] ?? 0, alpha: color["a"] ?? 1)
        }
        if let para = formatting["paragraph"] as? [String: Any] {
            let style = NSMutableParagraphStyle()
            if let alignment = para["alignment"] as? String { style.alignment = ["left": .left, "right": .right, "center": .center, "justified": .justified, "justify": .justified][alignment] ?? .natural }
            else if let alignment = para["alignment"] as? Int { style.alignment = [NSTextAlignment.left, .right, .center, .justified, .natural][min(4, max(0, alignment))] }
            style.paragraphSpacing = para["spaceAfter"] as? Double ?? 0
            style.paragraphSpacingBefore = para["spaceBefore"] as? Double ?? 0
            style.headIndent = para["leftIndent"] as? Double ?? 0
            style.firstLineHeadIndent = style.headIndent + (para["firstLineIndent"] as? Double ?? 0)
            style.lineHeightMultiple = para["lineSpacing"] as? Double ?? 1
            attributes[.paragraphStyle] = style
        }
        return attributes
    }

    @MainActor
    private func writePages(_ text: NSAttributedString, to destination: URL) throws {
        let context = try pagesContext()
        let ns = text.string as NSString
        var blocks: [[String: Any]] = []
        var position = 0
        while position < text.length {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: position, length: 0))
            var count = paragraphRange.length
            while count > 0 && [10, 13].contains(Int(ns.character(at: paragraphRange.location + count - 1))) { count -= 1 }
            let range = NSRange(location: paragraphRange.location, length: count)
            let paragraphText = ns.substring(with: range)
            var block: [String: Any] = ["kind": "paragraph", "text": paragraphText, "rtl": startsRightToLeft(paragraphText)]
            let style = text.attribute(.paragraphStyle, at: position, effectiveRange: nil) as? NSParagraphStyle
            guard style?.textBlocks.isEmpty ?? true else { throw Failure.message("Editable table conversion to Pages is not implemented in this local build. Choose PDF to retain the table layout.") }
            if let style {
                let alignment: String = style.alignment == .center ? "center" : style.alignment == .right ? "right" : style.alignment == .justified ? "justified" : "left"
                block["paragraph"] = ["alignment": alignment, "spaceAfter": style.paragraphSpacing, "spaceBefore": style.paragraphSpacingBefore, "leftIndent": style.headIndent, "firstLineIndent": style.firstLineHeadIndent - style.headIndent]
                block["rtl"] = style.baseWritingDirection == .rightToLeft || (style.baseWritingDirection == .natural && startsRightToLeft(paragraphText))
            }
            var runs: [[String: Any]] = []
            var links: [[String: Any]] = []
            var images: [[String: Any]] = []
            var attachmentError: Error?
            text.enumerateAttributes(in: range) { attributes, run, _ in
                var formatting: [String: Any] = [:]
                if let font = attributes[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    formatting["fontName"] = font.fontName
                    formatting["fontSize"] = font.pointSize
                    formatting["bold"] = traits.contains(.boldFontMask)
                    formatting["italic"] = traits.contains(.italicFontMask)
                }
                if let underline = attributes[.underlineStyle] as? Int { formatting["underline"] = underline != 0 }
                if let strike = attributes[.strikethroughStyle] as? Int { formatting["strikethru"] = strike != 0 }
                if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB) { formatting["fontColor"] = ["r": color.redComponent, "g": color.greenComponent, "b": color.blueComponent, "a": color.alphaComponent] }
                let start = run.location - range.location
                runs.append(["start": start, "end": start + run.length, "formatting": formatting])
                if let link = attributes[.link] { links.append(["start": start, "end": start + run.length, "url": String(describing: link)]) }
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                        attachmentError = Failure.message("A document attachment cannot be converted into a Pages image."); return
                    }
                    let width = min(504, max(1, image.size.width))
                    let height = max(1, image.size.height * width / max(1, image.size.width))
                    images.append(["start": start, "data": png.base64EncodedString(), "width": width, "height": height])
                }
            }
            if let attachmentError { throw attachmentError }
            block["runs"] = runs
            block["links"] = links
            block["inlineImages"] = images
            blocks.append(block)
            position = NSMaxRange(paragraphRange)
        }
        let model: [String: Any] = ["paper": ["pageWidth": 612, "pageHeight": 792, "leftMargin": 54, "rightMargin": 54, "topMargin": 54, "bottomMargin": 54], "contentWidth": 504, "structured": true, "blocks": blocks]
        let modelData = try JSONSerialization.data(withJSONObject: model)
        let template = try Data(contentsOf: requiredResource("PagesTemplate.pages"))
        let encoded = try call(context, "writePages", [String(decoding: modelData, as: UTF8.self), template.base64EncodedString()])
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { throw Failure.message("The Pages writer returned invalid data.") }
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Browser-based Office pagination

    @MainActor
    private func renderOfficePDF(source: URL, destination: URL) async throws {
        let renderer = OfficeRenderer()
        var request: [String: Any]
        if source.pathExtension.lowercased() == "docx" {
            request = ["kind": "docx", "data": try Data(contentsOf: source).base64EncodedString()]
        } else {
            var model = try pagesModel(source)
            var assets = model["assets"] as? [[String: Any]] ?? []
            for i in assets.indices {
                guard let encoded = assets[i]["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.message("A Pages image could not be decoded for rendering.") }
                assets[i]["url"] = "data:image/png;base64," + png.base64EncodedString()
            }
            model["assets"] = assets
            request = ["kind": "pages", "model": model]
        }
        let script = try String(contentsOf: requiredResource("OfficePreview.js"), encoding: .utf8)
        let data = try await renderer.render(script: script, request: request)
        try data.write(to: destination, options: .atomic)
    }

    @MainActor
    private final class OfficeRenderer: NSObject, WKNavigationDelegate {
        private var navigation: CheckedContinuation<Void, Error>?
        private let web: WKWebView
        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056), configuration: config)
            super.init()
            web.navigationDelegate = self
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { self.navigation?.resume(); self.navigation = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.navigation?.resume(throwing: error); self.navigation = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.navigation?.resume(throwing: error); self.navigation = nil }
        func render(script: String, request: [String: Any]) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                web.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob: file:; font-src data: blob: file:; connect-src 'none'\"></head><body></body></html>", baseURL: nil)
            }
            _ = try await web.evaluateJavaScript(script)
            let ready = try await web.callAsyncJavaScript("return await globalThis.prepareOffice(request)", arguments: ["request": request], in: nil, contentWorld: .page)
            guard let count = (ready as? [String: Any])?["count"] as? Int, count > 0 && count <= 10_000 else { throw Failure.message("The Office document has no renderable pages.") }
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure.message("Could not initialize Office PDF output.") }
            for index in 0..<count {
                try Task.checkCancellation()
                let result = try await web.callAsyncJavaScript("return await globalThis.selectOfficePage(index)", arguments: ["index": index], in: nil, contentWorld: .page)
                guard let page = result as? [String: Any], let width = page["width"] as? Double, let height = page["height"] as? Double,
                      width.isFinite && height.isFinite && width > 0 && height > 0 && width < 20_000 && height < 20_000 else { throw Failure.message("The document returned an invalid page size.") }
                web.setFrameSize(NSSize(width: width * 4 / 3, height: height * 4 / 3))
                _ = try await web.evaluateJavaScript("document.body.getBoundingClientRect().height")
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: width * 4 / 3, height: height * 4 / 3)
                let rendered = try await web.pdf(configuration: config)
                guard let provider = CGDataProvider(data: rendered as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { throw Failure.message("A rendered document page could not be read.") }
                var box = CGRect(x: 0, y: 0, width: width, height: height)
                context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                context.saveGState()
                context.concatenate(page.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: false))
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }
    }

    // MARK: - Raster PDF output and EPUB

    @MainActor
    private func renderPDFImages(source: URL, destination: URL, format: String) throws {
        guard let document = CGPDFDocument(source as CFURL), !document.isEncrypted || document.isUnlocked else { throw Failure.message("The PDF is unreadable or password protected.") }
        guard document.numberOfPages > 0 && document.numberOfPages <= 1000 else { throw Failure.message("The PDF must contain between 1 and 1,000 pages.") }
        if document.numberOfPages > 1 { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
        for i in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: i) else { throw Failure.message("A PDF page is missing.") }
            var size = page.getBoxRect(.cropBox).size
            if abs(page.rotationAngle) % 180 == 90 { size = CGSize(width: size.height, height: size.width) }
            guard size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 else { throw Failure.message("A PDF page has invalid dimensions.") }
            let scale = min(2, min(16_000 / size.width, 16_000 / size.height), sqrt(64_000_000 / (size.width * size.height)))
            let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.message("Could not allocate a PDF page image.") }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            // CGPDFPage's fitting transform does not upscale small pages. Scale
            // the bitmap context explicitly so 144 dpi really doubles every point.
            context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw Failure.message("A PDF page could not be rendered.") }
            let path = document.numberOfPages == 1 ? destination : destination.appendingPathComponent(String(format: "page-%04d.%@", i, format))
            guard let output = CGImageDestinationCreateWithURL(path as CFURL, (format == "jpg" ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw Failure.message("Could not create a PDF page image.") }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw Failure.message("Could not finish writing a PDF page image.") }
        }
    }

    private func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writeEPUB(_ text: String, title: String, destination: URL) async throws {
        let folder = destination.deletingLastPathComponent().appendingPathComponent("epub-source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        func put(_ path: String, _ value: String) throws { try value.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let name = xml(title), identifier = UUID().uuidString
        try put("mimetype", "application/epub+zip")
        try put("META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
        let paragraphs = text.components(separatedBy: .newlines).map { "<p>\(xml($0))</p>" }.joined(separator: "\n")
        try put("OEBPS/chapter.xhtml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(name)</title></head><body><h1>\(name)</h1>\(paragraphs)</body></html>")
        try put("OEBPS/nav.xhtml", "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">\(name)</a></li></ol></nav></body></html>")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.string(from: Date())
        try put("OEBPS/content.opf", "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">urn:uuid:\(identifier)</dc:identifier><dc:title>\(name)</dc:title><dc:language>und</dc:language><meta property=\"dcterms:modified\">\(date)</meta></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>")
        _ = try await process(URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-X", "-0", destination.path, "mimetype"], directory: folder)
        _ = try await process(URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-X", "-r", destination.path, "META-INF", "OEBPS"], directory: folder)
    }

    // MARK: - Unmodified Java helper command-line boundary

    private func requiredResource(_ relative: String) throws -> URL {
        let url = resources.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.message("The local converter is missing its \(relative) resource.") }
        return url
    }

    private func java(className: String, source: URL, destination: URL, target: String) async throws {
        let fm = FileManager.default
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var candidates = [resources.appendingPathComponent("PowerPoint/\(architecture)/bin/java")]
        if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"] { candidates.append(URL(fileURLWithPath: javaHome).appendingPathComponent("bin/java")) }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/jdk/Contents/Home/bin/java"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/java"))
        guard let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { throw Failure.message("This conversion requires the bundled Java runtime.") }
        _ = try requiredResource("PowerPoint/lib/tangerine-powerpoint.jar")
        let library = try requiredResource("PowerPoint/lib")
        let jars = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jar" }.map(\.path).sorted().joined(separator: ":")
        let output = try await process(executable, arguments: ["-Djava.awt.headless=true", "-Xmx1024m", "-cp", jars, className, target, source.path, destination.path], directory: destination.deletingLastPathComponent())
        guard output.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("OK\t") }) else { throw Failure.message("The document engine did not verify its output. \(output.suffix(1200))") }
    }

    /// Logs use files so a large stderr/stdout stream cannot fill a pipe and deadlock.
    private func process(_ executable: URL, arguments: [String], directory: URL) async throws -> String {
        let log = directory.appendingPathComponent(".engine-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw Failure.message("Could not create a conversion log.") }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = handle
        task.standardError = handle
        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try task.run() }
                catch { task.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        }, onCancel: { if task.isRunning { task.terminate() } })
        try Task.checkCancellation()
        try handle.synchronize()
        let data = try Data(contentsOf: log)
        let output = String(decoding: data.suffix(32_768), as: UTF8.self)
        guard status == 0 else { throw Failure.message(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The conversion engine stopped with status \(status)." : String(output.suffix(4000))) }
        return output
    }
}
