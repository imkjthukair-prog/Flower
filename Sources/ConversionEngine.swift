import Foundation
import AppKit
import AVFoundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// A local reconstruction. Defaults are explicit choices, not recovered Tangerine source.
final class ConversionEngine: @unchecked Sendable {
    private let resources: URL
    private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "webp", "avif"]
    private static let audio: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma"]
    private static let video: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
    private static let imageOutputs = ["jpg", "png", "heic", "tiff", "bmp", "webp"]
    private static let audioOutputs = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    private static let videoOutputs = ["mp4", "mov", "mkv", "avi", "wmv", "gif"]
    private static let archives: Set<String> = ["zip", "tar", "gz", "gzip", "tgz"]

    init(resources: URL) { self.resources = resources }

    static func targets(for ext: String) -> [String] {
        let ext = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var result: [String]
        if images.contains(ext) { result = imageOutputs }
        else if ext == "gif" { result = imageOutputs + videoOutputs }
        else if audio.contains(ext) { result = audioOutputs }
        else if video.contains(ext) { result = videoOutputs + audioOutputs }
        else if ext == "srt" || ext == "vtt" { result = ["srt", "vtt", "txt"] }
        else if archives.contains(ext) { result = ["zip", "tar", "gzip"] }
        else { result = [] }
        result += DocumentEngine.targets(for: ext)
        var seen = Set<String>()
        return result.filter { $0 != ext && seen.insert($0).inserted }
    }

    @MainActor func convert(source: URL, destination: URL, target: String) async throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let target = target.lowercased()
        guard source.isFileURL, destination.isFileURL else { throw EngineError.message("Choose local files.") }
        guard FileManager.default.fileExists(atPath: source.path) else { throw EngineError.message("The source file is missing.") }
        guard source != destination else { throw EngineError.message("The original cannot be replaced.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw EngineError.message("A file already exists at the output path.") }
        let ext = source.pathExtension.lowercased()
        guard Self.targets(for: ext).contains(target) else { throw EngineError.message("Conversion from \(ext.uppercased()) to \(target.uppercased()) is not available in this build.") }
        // The document engine owns its staging/publication and can produce directories.
        if DocumentEngine.targets(for: ext).contains(target) && !Self.isNativePair(ext, target) {
            try await DocumentEngine(resources: resources).convert(source: source, destination: destination, target: target)
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".local-conversion-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("result." + (target == "gzip" ? "gz" : target))
        if Self.images.contains(ext) || (ext == "gif" && Self.imageOutputs.contains(target)) {
            try await convertImage(source, output, target)
        } else if Self.audio.contains(ext) || Self.video.contains(ext) || ext == "gif" {
            try await convertMedia(source, output, target)
        } else if ext == "srt" || ext == "vtt" {
            try await Task.detached(priority: .userInitiated) { try Self.convertSubtitle(source, output, target) }.value
        } else if Self.archives.contains(ext) {
            try await convertArchive(source, output, target, workspace: temporary)
        } else { throw EngineError.message("This conversion is not implemented.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw EngineError.message("The converter did not create a nonempty output.") }
        // FileManager refuses an existing destination; no original or prior output is overwritten.
        try FileManager.default.moveItem(at: output, to: destination)
    }

    private static func isNativePair(_ ext: String, _ target: String) -> Bool {
        if images.contains(ext) { return imageOutputs.contains(target) }
        if ext == "gif" { return imageOutputs.contains(target) || videoOutputs.contains(target) }
        if audio.contains(ext) { return audioOutputs.contains(target) }
        if video.contains(ext) { return (videoOutputs + audioOutputs).contains(target) }
        if ["srt", "vtt"].contains(ext) { return ["srt", "vtt", "txt"].contains(target) }
        return archives.contains(ext) && ["zip", "tar", "gzip"].contains(target)
    }

    private func helper(_ name: String) throws -> URL {
        for candidate in [resources.appendingPathComponent("Tools/" + name), resources.appendingPathComponent(name)] {
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw EngineError.message("The local build is missing its \(name) helper.")
    }

    private func convertImage(_ source: URL, _ output: URL, _ target: String) async throws {
        if target == "webp" {
            let input = output.deletingLastPathComponent().appendingPathComponent("webp-input.png")
            try await Task.detached { try Self.imageIO(source, input, "png") }.value
            try await Self.run(helper("ffmpeg"), ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", input.path, "-c:v", "libwebp", "-q:v", "82", output.path])
        } else {
            try await Task.detached(priority: .userInitiated) { try Self.imageIO(source, output, target) }.value
        }
    }

    private static func imageIO(_ source: URL, _ output: URL, _ target: String) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw EngineError.message("macOS could not decode this image.") }
        let types = ["jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff", "bmp": "com.microsoft.bmp"]
        guard let uti = types[target], (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(uti) else { throw EngineError.message("macOS does not provide this image encoder.") }
        if target == "jpg", let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let composited = context.makeImage() { image = composited }
        }
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, uti as CFString, 1, nil) else { throw EngineError.message("Could not create the output image.") }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.88
        CGImageDestinationAddImage(writer, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw EngineError.message("The image encoder could not finish.") }
        guard let check = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(check) > 0 else { throw EngineError.message("The output image could not be verified.") }
    }

    private func convertMedia(_ source: URL, _ output: URL, _ target: String) async throws {
        let ffmpeg = try helper("ffmpeg")
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", source.path]
        if Self.audioOutputs.contains(target) {
            args += ["-vn", "-map", "0:a:0"]
            switch target {
            case "mp3": args += ["-c:a", "libmp3lame", "-b:a", "192k"]
            case "m4a": args += ["-c:a", "aac", "-b:a", "192k"]
            case "wav": args += ["-c:a", "pcm_s16le"]
            case "flac": args += ["-c:a", "flac"]
            case "ogg": args += ["-c:a", "vorbis", "-strict", "experimental", "-b:a", "192k", "-ac", "2"]
            case "opus": args += ["-c:a", "opus", "-strict", "experimental", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
            case "aiff": args += ["-c:a", "pcm_s16be"]
            case "wma": args += ["-c:a", "wmav2", "-b:a", "192k"]
            default: break
            }
        } else if target == "gif" {
            args += ["-an", "-filter_complex", "fps=15,scale=min(640\\,iw):-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        } else {
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p"]
            switch target {
            case "wmv": args += ["-c:v", "wmv2", "-b:v", "4000k", "-c:a", "wmav2", "-b:a", "192k"]
            case "avi": args += ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", "192k"]
            default: args += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "5000k", "-c:a", "aac", "-b:a", "192k"]
            }
            if target == "mov" || target == "mp4" { args += ["-movflags", "+faststart"] }
        }
        args += [output.path]
        try await Self.run(ffmpeg, args)
    }

    private struct Cue { let start: String; let end: String; let text: String }
    private static func convertSubtitle(_ source: URL, _ output: URL, _ target: String) throws {
        let raw = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let pattern = #"(?m)^\s*((?:\d{2,}:)?\d{2}:\d{2}[.,]\d{3})\s*-->\s*((?:\d{2,}:)?\d{2}:\d{2}[.,]\d{3})[^\n]*\n([^\n]*(?:\n(?!\s*\n)[^\n]*)*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = raw as NSString
        let cues = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { match in
            Cue(start: ns.substring(with: match.range(at: 1)), end: ns.substring(with: match.range(at: 2)), text: ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !cues.isEmpty else { throw EngineError.message("No valid subtitle cues were found. Use UTF-8 SRT or WebVTT.") }
        func time(_ value: String, separator: String) -> String {
            let normalized = value.replacingOccurrences(of: ",", with: ".")
            let full = normalized.filter { $0 == ":" }.count == 1 ? "00:" + normalized : normalized
            return full.replacingOccurrences(of: ".", with: separator)
        }
        let text: String
        if target == "txt" { text = cues.map(\.text).joined(separator: "\n\n") + "\n" }
        else {
            let separator = target == "srt" ? "," : "."
            text = (target == "vtt" ? "WEBVTT\n\n" : "") + cues.enumerated().map { index, cue in
                (target == "srt" ? "\(index + 1)\n" : "") + time(cue.start, separator: separator) + " --> " + time(cue.end, separator: separator) + "\n" + cue.text
            }.joined(separator: "\n\n") + "\n"
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    private func convertArchive(_ source: URL, _ output: URL, _ target: String, workspace: URL) async throws {
        let directory = workspace.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let ext = source.pathExtension.lowercased()
        // A tar.gz is a compressed archive, not a single opaque .tar member.
        // Match the compound suffix before the ordinary GZIP route.
        let compressedTar = source.lastPathComponent.lowercased().hasSuffix(".tar.gz")
        if (ext == "gz" || ext == "gzip") && !compressedTar {
            let name = source.deletingPathExtension().lastPathComponent
            let unpacked = directory.appendingPathComponent(name.isEmpty ? "content" : name)
            try await Self.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", source.path], output: unpacked)
        } else {
            let tar = URL(fileURLWithPath: "/usr/bin/tar")
            let list = try await Self.run(tar, ["-tf", source.path])
            for name in list.components(separatedBy: .newlines) where !name.isEmpty {
                guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw EngineError.message("This archive contains an unsafe path.") }
            }
            let verbose = try await Self.run(tar, ["-tvf", source.path])
            guard !verbose.components(separatedBy: .newlines).contains(where: { $0.first == "l" || $0.first == "h" }) else { throw EngineError.message("Archive conversion in this build does not accept symbolic or hard links.") }
            try await Self.run(tar, ["-xf", source.path, "-C", directory.path, "--no-same-owner", "--no-same-permissions"])
        }
        if target == "zip" {
            try await Self.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", directory.path, output.path])
        } else if target == "tar" {
            try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", output.path, "-C", directory.path, "."])
        } else {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            guard entries.count == 1, try entries[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw EngineError.message("GZIP holds one file. Choose ZIP or TAR for an archive containing multiple items.") }
            try await Self.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-c", "--", entries[0].path], output: output)
        }
    }

    /// Runs outside the main actor. File-backed logs prevent pipe-buffer deadlock.
    @discardableResult private static func run(_ executable: URL, _ arguments: [String], output: URL? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-converter-process-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let stdout = output ?? directory.appendingPathComponent("stdout")
            let stderr = directory.appendingPathComponent("stderr")
            guard FileManager.default.createFile(atPath: stdout.path, contents: nil), FileManager.default.createFile(atPath: stderr.path, contents: nil) else { throw EngineError.message("Could not prepare converter output.") }
            let outHandle = try FileHandle(forWritingTo: stdout), errorHandle = try FileHandle(forWritingTo: stderr)
            defer { try? outHandle.close(); try? errorHandle.close() }
            let process = Process()
            process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outHandle; process.standardError = errorHandle
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = try Data(contentsOf: stderr)
                let detail = String(decoding: data.suffix(6000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw EngineError.message(detail.isEmpty ? "\(executable.lastPathComponent) failed (\(process.terminationStatus))." : detail)
            }
            return output == nil ? String(decoding: try Data(contentsOf: stdout), as: UTF8.self) : ""
        }.value
    }

    enum EngineError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
