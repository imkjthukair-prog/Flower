import Foundation
import AppKit
import AVFoundation
import PDFKit
import ImageIO
import Vision

struct LocalTool: Identifiable { let id: String; let title: String }

final class FileToolEngine: @unchecked Sendable {
    let resources: URL
    init(resources: URL) { self.resources = resources }
    private static let images: Set<String> = ["png","jpg","jpeg","heic","heif","tiff","tif","bmp","webp","avif"]
    private static let imageCompressionFormats: [String: (extension: String, type: String)] = [
        "png": ("png", "public.png"), "jpg": ("jpg", "public.jpeg"), "jpeg": ("jpg", "public.jpeg"),
        "heic": ("heic", "public.heic"), "heif": ("heic", "public.heic"),
        "tiff": ("tiff", "public.tiff"), "tif": ("tiff", "public.tiff"),
        "webp": ("webp", "org.webmproject.webp")
    ]
    private static let videos: Set<String> = ["mp4","mov","mkv","webm","avi","wmv"]
    private static let audio: Set<String> = ["mp3","m4a","wav","flac","ogg","opus","aiff","aif","wma"]

    static func tools(for urls: [URL]) -> [LocalTool] {
        guard !urls.isEmpty else { return [] }
        let extensions = urls.map { $0.pathExtension.lowercased() }
        var pairs: [(String,String)] = []
        if extensions.allSatisfy({ images.contains($0) }) {
            pairs += [("createPDF","Create PDF"),("createCollage","Create Image Collage")]
            if urls.count == 1 {
                if imageCompressionFormats[extensions[0]] != nil { pairs += [("compress","Compress")] }
                pairs += [("removeMetadata","Strip Image Metadata"),("rotateImage","Rotate Image"),("flipImage","Flip Image"),("cropImage","Crop Image"),("readQRCode","Read QR Codes")]
            }
        }
        if extensions.allSatisfy({ $0 == "pdf" }) {
            if urls.count > 1 { pairs += [("mergePDF","Merge PDFs")] }
            if urls.count == 1 { pairs += [("splitPDF","Split PDF Pages"),("organizePDF","Organize PDF Pages")] }
        }
        if urls.count == 1, let ext = extensions.first {
            if videos.contains(ext) { pairs += [("muteVideo","Mute Video"),("trimVideo","Trim Video"),("changeVideoSpeed","Change Video Speed"),("cropVideo","Crop Video"),("videoSnapshots","Save Video Snapshot")] }
            if audio.contains(ext) { pairs += [("compress","Compress to MP3"),("trimAudio","Trim Audio"),("audioChannels","Convert Audio Channels"),("normalizeAudio","Normalize Audio")] }
        }
        return pairs.map { LocalTool(id:$0.0,title:$0.1) }
    }

    static func isImageCompressionSource(_ source: URL) -> Bool { images.contains(source.pathExtension.lowercased()) }

    static func outputExtension(for id: String, source: URL) -> String {
        switch id {
        case "createPDF","mergePDF","organizePDF": return "pdf"
        case "splitPDF": return ""
        case "readQRCode": return "txt"
        case "compress":
            let ext = source.pathExtension.lowercased()
            return images.contains(ext) ? imageCompressionFormats[ext]?.extension ?? ext : "mp3"
        case "trimAudio","audioChannels","normalizeAudio": return "wav"
        case "trimVideo","changeVideoSpeed","muteVideo","cropVideo": return "mp4"
        default: return "png"
        }
    }

    @MainActor func perform(_ id: String, sources: [URL], destination: URL, parameters: [String:String]) async throws {
        if id == "compress", let first = sources.first, Self.isImageCompressionSource(first), Self.imageCompressionFormats[first.pathExtension.lowercased()] == nil {
            throw Failure("Compression that preserves \(first.pathExtension.uppercased()) is not available. Choose another format with Convert instead.")
        }
        guard Self.tools(for:sources).contains(where:{$0.id == id}) else { throw Failure("This tool is unavailable for the selected files.") }
        guard destination.isFileURL, sources.allSatisfy(\.isFileURL) else { throw Failure("Choose local files.") }
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw Failure("The output already exists. Choose another name.") }
        guard !sources.contains(where:{$0.standardizedFileURL == destination.standardizedFileURL}) else { throw Failure("The original cannot be replaced.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".local-tool-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:staging) }
        let output = staging.appendingPathComponent(id == "splitPDF" ? "pages" : "output."+Self.outputExtension(for:id,source:sources[0]))
        let imageTools = ["removeMetadata","rotateImage","flipImage","cropImage","createCollage","readQRCode"]
        if id == "compress" && Self.isImageCompressionSource(sources[0]) {
            try await compressImage(source: sources[0], output: output, parameters: parameters)
        } else if imageTools.contains(id) {
            try await Task.detached(priority:.userInitiated) { try Self.imageTool(id,sources:sources,output:output,parameters:parameters) }.value
        } else if ["createPDF","mergePDF","splitPDF","organizePDF"].contains(id) {
            try await Task.detached(priority:.userInitiated) { try Self.pdfTool(id,sources:sources,output:output,parameters:parameters) }.value
        } else { try await mediaTool(id,source:sources[0],output:output,parameters:parameters) }
        guard FileManager.default.fileExists(atPath:output.path) else { throw Failure("The tool did not create an output.") }
        if id != "splitPDF" {
            let size = try FileManager.default.attributesOfItem(atPath:output.path)[.size] as? NSNumber
            guard (size?.int64Value ?? 0) > 0 else { throw Failure("The output is empty.") }
        }
        try FileManager.default.moveItem(at:output,to:destination)
    }

    private static func number(_ key:String, _ p:[String:String], default fallback:Double? = nil, range:ClosedRange<Double>? = nil) throws -> Double {
        let value: Double
        if let raw=p[key], !raw.trimmingCharacters(in:.whitespaces).isEmpty {
            guard let parsed=Double(raw), parsed.isFinite else { throw Failure("Enter a valid number for \(key).") }; value=parsed
        } else if let fallback=fallback { value=fallback }
        else { throw Failure("Enter \(key) for this tool.") }
        if let range=range, !range.contains(value) { throw Failure("\(key) must be between \(range.lowerBound) and \(range.upperBound).") }
        return value
    }

    private static func image(_ url:URL) throws -> CGImage {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any] else { throw Failure("Could not read the image.") }
        let width=(props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1
        let height=(props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1
        guard width > 0,height > 0,Double(width)*Double(height)<=100_000_000 else { throw Failure("The image exceeds this tool's 100 megapixel limit.") }
        let opts:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(width,height)]
        guard let img=CGImageSourceCreateThumbnailAtIndex(src,0,opts as CFDictionary) else { throw Failure("Could not decode the image.") };return img
    }
    private static func canvas(_ width:Int,_ height:Int) throws -> CGContext {
        guard width > 0,height > 0,width <= 16384,height <= 16384,Double(width)*Double(height)<=100_000_000,
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure("The requested image dimensions are too large or invalid.") }
        context.interpolationQuality = .high;return context
    }
    private static func save(_ image:CGImage,_ output:URL,jpeg:Bool=false,quality:Double=0.75) throws {
        guard let writer=CGImageDestinationCreateWithURL(output as CFURL,(jpeg ? "public.jpeg":"public.png") as CFString,1,nil) else { throw Failure("Could not create the image output.") }
        CGImageDestinationAddImage(writer,image,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw Failure("Could not finish the image output.") }
    }
    private static func imageTool(_ id:String,sources:[URL],output:URL,parameters p:[String:String]) throws {
        if id == "createCollage" {
            let columns=Int(try number("columns",p,default:ceil(sqrt(Double(sources.count))),range:1...20))
            let cell=Int(try number("cellSize",p,default:512,range:32...2048)),gap=Int(try number("gap",p,default:16,range:0...200))
            let rows=(sources.count+columns-1)/columns,w=columns*cell+(columns+1)*gap,h=rows*cell+(rows+1)*gap
            let ctx=try canvas(w,h);ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h))
            for (i,url) in sources.enumerated() {
                let img=try image(url),scale=min(Double(cell)/Double(img.width),Double(cell)/Double(img.height))
                let iw=Double(img.width)*scale,ih=Double(img.height)*scale
                let x=Double(gap+(i%columns)*(cell+gap))+(Double(cell)-iw)/2
                let y=Double(h-gap-(i/columns+1)*cell-(i/columns)*gap)+(Double(cell)-ih)/2
                ctx.draw(img,in:CGRect(x:x,y:y,width:iw,height:ih))
            }
            guard let result=ctx.makeImage() else { throw Failure("Could not render the collage.") };try save(result,output);return
        }
        let img=try image(sources[0])
        if id == "readQRCode" {
            let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
            try VNImageRequestHandler(cgImage:img).perform([request])
            let texts=(request.results ?? []).compactMap(\.payloadStringValue)
            guard !texts.isEmpty else { throw Failure("No readable QR code was found.") }
            try (texts.joined(separator:"\n\n")+"\n").write(to:output,atomically:true,encoding:.utf8);return
        }
        if id == "cropImage" {
            let x=Int(try number("x",p,default:0,range:0...Double(img.width-1))),y=Int(try number("y",p,default:0,range:0...Double(img.height-1)))
            let w=Int(try number("width",p,range:1...Double(img.width))),h=Int(try number("height",p,range:1...Double(img.height)))
            guard x+w <= img.width,y+h <= img.height,let cropped=img.cropping(to:CGRect(x:x,y:y,width:w,height:h)) else { throw Failure("The crop must stay inside the image.") }
            try save(cropped,output);return
        }
        if id == "rotateImage" {
            let degrees=Int(try number("degrees",p,default:90))
            guard [90,180,270,-90,-180,-270].contains(degrees) else { throw Failure("Use a 90, 180, or 270 degree rotation.") }
            let swap=abs(degrees)%180==90,w=swap ? img.height:img.width,h=swap ? img.width:img.height
            let ctx=try canvas(w,h);ctx.translateBy(x:Double(w)/2,y:Double(h)/2);ctx.rotate(by:-Double(degrees)*Double.pi/180)
            let rect = CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height))
            ctx.draw(img, in: rect)
            guard let result=ctx.makeImage() else { throw Failure("Could not rotate the image.") };try save(result,output);return
        }
        if id == "flipImage" {
            let axis=p["axis"] ?? "horizontal";guard ["horizontal","vertical"].contains(axis) else {throw Failure("axis must be horizontal or vertical.")}
            let ctx=try canvas(img.width,img.height)
            if axis == "horizontal" {ctx.translateBy(x:Double(img.width),y:0);ctx.scaleBy(x:-1,y:1)} else {ctx.translateBy(x:0,y:Double(img.height));ctx.scaleBy(x:1,y:-1)}
            ctx.draw(img,in:CGRect(x:0,y:0,width:img.width,height:img.height));guard let result=ctx.makeImage() else {throw Failure("Could not flip the image.")};try save(result,output);return
        }
        // Decode and re-encode a single upright raster frame with no source property dictionary.
        try save(img,output)
    }

    private struct CompressionImage: @unchecked Sendable {
        let image: CGImage
        let properties: [CFString: Any]
        let format: (extension: String, type: String)
        let sourceBytes: Int64
    }

    private static func compressionImage(_ source: URL) throws -> CompressionImage {
        guard let format = imageCompressionFormats[source.pathExtension.lowercased()],
              let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(reader) as String?,
              sourceType == format.type || (format.type == "public.heic" && sourceType == "public.heif") else {
            throw Failure("The image contents do not match a supported compression format.")
        }
        guard CGImageSourceGetCount(reader) == 1 else {
            throw Failure("Compression of animated or multi-page images is not supported. The original is unchanged.")
        }
        if format.extension == "png", try pngContainsChunk(source, named: "acTL") {
            throw Failure("Compression of animated PNGs is not supported. The original is unchanged.")
        }
        guard let originalProperties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              let width = originalProperties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = originalProperties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 100_000_000,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw Failure("Could not decode this image within the 100 megapixel limit.")
        }
        // Keep the decoded color space, pixel dimensions, orientation and print
        // resolution. Re-encoding never flattens alpha onto a white background.
        var properties: [CFString: Any] = [:]
        for key in [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = originalProperties[key] { properties[key] = value }
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        guard let bytes, bytes.int64Value > 0 else { throw Failure("The source image is empty.") }
        return CompressionImage(image: image, properties: properties, format: format, sourceBytes: bytes.int64Value)
    }

    private static func writeCompressionCandidate(_ input: CompressionImage, to destination: URL, quality: Double) throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(input.format.type),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, input.format.type as CFString, 1, nil) else {
            throw Failure("macOS does not provide an encoder for this image format.")
        }
        var properties = input.properties
        if input.format.extension != "tiff" { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        properties[kCGImageDestinationEmbedThumbnail] = false
        if input.format.extension == "png" { properties[kCGImagePropertyPNGCompressionFilter] = 0xf8 } // IMAGEIO_PNG_ALL_FILTERS.
        if input.format.extension == "tiff" { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] } // Lossless LZW.
        CGImageDestinationAddImage(writer, input.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw Failure("Could not finish the compressed image.") }
    }

    private static func validCompressionCandidate(_ candidate: URL, input: CompressionImage) -> Bool {
        guard let reader = CGImageSourceCreateWithURL(candidate as CFURL, nil), CGImageSourceGetCount(reader) == 1,
              CGImageSourceGetType(reader) as String? == input.format.type,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, nil),
              image.width == input.image.width, image.height == input.image.height else { return false }
        if input.format.extension == "png", [.first, .last, .premultipliedFirst, .premultipliedLast].contains(input.image.alphaInfo) {
            guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo) else { return false }
        }
        if input.format.extension == "png", image.bitsPerComponent != input.image.bitsPerComponent { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any]
        let originalOrientation = (input.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let resultOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard originalOrientation == resultOrientation else { return false }
        return true
    }

    private func compressImage(source: URL, output: URL, parameters: [String: String]) async throws {
        let input = try await Task.detached(priority: .userInitiated) { try Self.compressionImage(source) }.value
        let explicitQuality: Double? = parameters["quality"] == nil ? nil : try Self.number("quality", parameters, range: 0.05...1)
        let orientation = (input.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if input.format.extension == "png" {
            // FFmpeg's recovered PNG path strips metadata. Keep the original
            // when that would discard a display orientation or embedded ICC
            // profile; a smaller file must not change the image's appearance.
            let hasEmbeddedProfile = try Self.pngContainsChunk(source, named: "iCCP")
            if orientation != 1 || hasEmbeddedProfile {
                try FileManager.default.copyItem(at: source, to: output)
                return
            }
        } else if input.format.extension == "webp" && orientation != 1 {
            try FileManager.default.copyItem(at: source, to: output)
            return
        }
        let qualities: [Double]
        if let quality = explicitQuality { qualities = [quality] }
        else { qualities = input.format.extension == "jpg" ? [0.62, 0.50, 0.40] : [0.62] }

        var bestCandidate: URL?
        var bestBytes = input.sourceBytes
        for (index, quality) in qualities.enumerated() {
            let candidate = output.deletingLastPathComponent().appendingPathComponent("candidate-\(index)." + input.format.extension)
            if input.format.extension == "png" {
                let helper = resources.appendingPathComponent("Tools/ffmpeg")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Failure("The PNG compressor is missing.") }
                let handle = try FileHandle(forReadingFrom: source)
                let header = try handle.read(upToCount: 26) ?? Data()
                try handle.close()
                let indexed = header.count == 26 && header[25] == 3
                // Recovered original PNG preset: lossless FFmpeg PNG level 9,
                // mixed prediction for truecolor, none for indexed color.
                try await Self.run(helper, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-noautorotate", "-i", source.path, "-frames:v", "1", "-map_metadata", "-1", "-c:v", "png", "-compression_level", "9", "-pred", indexed ? "none" : "mixed", candidate.path])
            } else if input.format.extension == "webp" {
                let helper = resources.appendingPathComponent("Tools/ffmpeg")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Failure("The WebP compressor is missing.") }
                let intermediate = output.deletingLastPathComponent().appendingPathComponent("webp-input.png")
                try await Task.detached(priority: .userInitiated) { try Self.save(input.image, intermediate) }.value
                // The bundled cwebp lacks PNG input support. FFmpeg includes
                // libwebp and retains the intermediate's full alpha channel.
                try await Self.run(helper, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", intermediate.path, "-frames:v", "1", "-c:v", "libwebp", "-q:v", String(quality * 100), "-compression_level", "6", candidate.path])
            } else {
                try await Task.detached(priority: .userInitiated) { try Self.writeCompressionCandidate(input, to: candidate, quality: quality) }.value
            }
            guard Self.validCompressionCandidate(candidate, input: input) else { continue }
            let bytes = try FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? NSNumber
            if let bytes, bytes.int64Value > 0, bytes.int64Value < bestBytes {
                bestCandidate = candidate
                bestBytes = bytes.int64Value
                // Original balanced JPEG preset keeps trying its quality list
                // until the candidate reaches 80% of the source byte count.
                if input.format.extension != "jpg" || Double(bestBytes) <= Double(input.sourceBytes) * 0.8 { break }
            }
        }
        if let bestCandidate {
            try FileManager.default.moveItem(at: bestCandidate, to: output)
            return
        }
        // The original app's preset path copies the original when no candidate
        // is smaller. Preserve those bytes exactly instead of publishing growth.
        try FileManager.default.copyItem(at: source, to: output)
    }

    private static func pngContainsChunk(_ source: URL, named chunkName: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: 8)
        while let chunk = try handle.read(upToCount: 8), chunk.count == 8 {
            let length = chunk.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(decoding: chunk.suffix(4), as: UTF8.self)
            if type == chunkName { return true }
            if type == "IEND" { return false }
            try handle.seek(toOffset: handle.offset() + length + 4)
        }
        return false
    }

    private static func pdfTool(_ id:String,sources:[URL],output:URL,parameters p:[String:String]) throws {
        let result=PDFDocument()
        if id == "createPDF" {
            for url in sources {let img=try image(url);guard let page=PDFPage(image:NSImage(cgImage:img,size:NSSize(width:img.width,height:img.height))) else {throw Failure("Could not create a PDF page.")};result.insert(page,at:result.pageCount)}
        } else {
            guard let original=PDFDocument(url:sources[0]),!original.isLocked,original.pageCount>0 else {throw Failure("The PDF is empty, unreadable, or locked.")}
            if id == "splitPDF" {
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
                for i in 0..<original.pageCount {let doc=PDFDocument();guard let page=original.page(at:i) else {throw Failure("Could not read a PDF page.")};doc.insert(page,at:0);guard doc.write(to:output.appendingPathComponent(String(format:"Page %03d.pdf",i+1))) else {throw Failure("Could not write a PDF page.")}}
                return
            }
            if id == "mergePDF" {
                for url in sources {guard let doc=PDFDocument(url:url),!doc.isLocked,doc.pageCount>0 else {throw Failure("One of the PDFs is empty, unreadable, or locked.")};for i in 0..<doc.pageCount {guard let page=doc.page(at:i) else {throw Failure("Could not read a PDF page.")};result.insert(page,at:result.pageCount)}}
            } else {
                guard let raw=p["pages"],!raw.isEmpty else {throw Failure("Enter a comma-separated page order, for example 3,1,2.")}
                let pieces=raw.split(separator:",",omittingEmptySubsequences:false)
                let order=pieces.compactMap{Int($0.trimmingCharacters(in:.whitespaces))}
                guard order.count == pieces.count,!order.isEmpty,order.allSatisfy({(1...original.pageCount).contains($0)}) else {throw Failure("Every page number must be within the PDF.")}
                for index in order {guard let page=original.page(at:index-1)?.copy() as? PDFPage else {throw Failure("Could not copy a PDF page.")};result.insert(page,at:result.pageCount)}
            }
        }
        guard result.pageCount>0,result.write(to:output),let check=PDFDocument(url:output),check.pageCount==result.pageCount else {throw Failure("Could not verify the saved PDF.")}
    }

    private func mediaTool(_ id:String,source:URL,output:URL,parameters p:[String:String]) async throws {
        let ffmpeg=resources.appendingPathComponent("Tools/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath:ffmpeg.path) else {throw Failure("The FFmpeg helper is missing.")}
        var args=["-hide_banner","-loglevel","error","-nostdin","-n","-i",source.path]
        let isVideo=Self.videos.contains(source.pathExtension.lowercased())
        if id == "videoSnapshots" {
            let time=try Self.number("time",p,default:0,range:0...Double.greatestFiniteMagnitude)
            args += ["-ss",String(time),"-frames:v","1","-an",output.path];try await Self.run(ffmpeg,args);return
        }
        if id == "trimVideo" || id == "trimAudio" {
            let start=try Self.number("start",p,default:0,range:0...Double.greatestFiniteMagnitude),end=try Self.number("end",p,range:0...Double.greatestFiniteMagnitude)
            guard end>start else {throw Failure("end must be later than start.")}
            let info = try await probe(source, ffmpeg: ffmpeg)
            guard let duration = info.duration, duration > 0 else { throw Failure("Could not determine the source duration.") }
            guard start < duration, end <= duration + 0.02 else { throw Failure("The trim must be inside the file's \(String(format: "%.3f", duration))-second duration.") }
            args += ["-ss",String(start),"-t",String(end-start)]
        }
        if isVideo {
            args += ["-map","0:v:0"]
            if id == "muteVideo" {args += ["-an"]} else {args += ["-map","0:a:0?"]}
            var filters=["pad=ceil(iw/2)*2:ceil(ih/2)*2"]
            if id == "changeVideoSpeed" {
                let speed=try Self.number("speed",p,default:1.5,range:0.25...4)
                let asset = AVURLAsset(url: source)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw Failure("Could not read the video's frame rate.") }
                let rate = Double(try await track.load(.nominalFrameRate))
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                guard rate.isFinite, rate > 0, duration.isFinite, duration > 0 else { throw Failure("Could not read this video's timing.") }
                args += ["-r", String(rate * speed), "-t", String(duration / speed)]
                filters.insert("setpts=(PTS-STARTPTS)/\(speed)",at:0)
                var remaining=speed,tempo:[String]=[]
                while remaining>2 {tempo.append("atempo=2");remaining/=2}
                while remaining<0.5 {tempo.append("atempo=0.5");remaining/=0.5}
                tempo.append("atempo=\(remaining)");args += ["-af",tempo.joined(separator:",")]
            }
            if id == "cropVideo" {
                let x=try Self.number("x",p,default:0,range:0...16384),y=try Self.number("y",p,default:0,range:0...16384)
                let w=try Self.number("width",p,range:2...16384),h=try Self.number("height",p,range:2...16384)
                guard [x,y,w,h].allSatisfy({ $0.rounded() == $0 }), Int(w) % 2 == 0, Int(h) % 2 == 0 else { throw Failure("Use whole pixels and an even crop width and height.") }
                let info = try await probe(source, ffmpeg: ffmpeg)
                guard let size = info.size else { throw Failure("Could not determine the displayed video dimensions.") }
                guard x + w <= size.width, y + h <= size.height else { throw Failure("The crop must be inside the \(Int(size.width)) × \(Int(size.height)) video frame.") }
                filters.insert("crop=\(Int(w)):\(Int(h)):\(Int(x)):\(Int(y)):exact=1",at:0)
            }
            args += ["-vf",filters.joined(separator:","),"-c:v","h264_videotoolbox","-allow_sw","1","-b:v","5000k","-pix_fmt","yuv420p","-c:a","aac","-b:a","192k","-movflags","+faststart"]
        } else {
            args += ["-vn","-map","0:a:0"]
            if id == "audioChannels" {let channels=Int(try Self.number("channels",p,default:2,range:1...2));args += ["-ac",String(channels)]}
            if id == "normalizeAudio" {let loudness=try Self.number("loudness",p,default:-16,range:-70 ... -5);args += ["-af","loudnorm=I=\(loudness):TP=-1.5:LRA=11","-ar","48000"]}
            if id == "compress" {let bitrate=Int(try Self.number("bitrate",p,default:128,range:32...320));args += ["-c:a","libmp3lame","-b:a","\(bitrate)k"]} else {args += ["-c:a","pcm_s16le"]}
        }
        args += [output.path];try await Self.run(ffmpeg,args)
        let verified = try await probe(output, ffmpeg: ffmpeg)
        guard let duration = verified.duration, duration > 0 else { throw Failure("The output contains no playable duration.") }
        let decoded = try await Self.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-progress", "pipe:1", "-nostats", "-i", output.path, "-t", "0.5", "-f", "null", "-"])
        let times = decoded.components(separatedBy: .newlines).filter { $0.hasPrefix("out_time_us=") }.compactMap { Int64($0.dropFirst("out_time_us=".count)) }
        let frames = decoded.components(separatedBy: .newlines).filter { $0.hasPrefix("frame=") }.compactMap { Int($0.dropFirst("frame=".count).trimmingCharacters(in: .whitespaces)) }
        guard times.contains(where: { $0 > 0 }) || frames.contains(where: { $0 > 0 }) else { throw Failure("The output contains no decodable media frames.") }
    }

    private struct MediaProbe { let duration: Double?; let size: CGSize? }
    private func probe(_ url: URL, ffmpeg: URL) async throws -> MediaProbe {
        let text = try await Self.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path], acceptedStatuses: [0,1])
        let ns = text as NSString
        func groups(_ pattern: String) throws -> [String]? {
            guard let match = try NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
        }
        var duration: Double?
        if let t = try groups(#"Duration: (\d+):(\d+):([0-9.]+)"#), let h=Double(t[0]), let m=Double(t[1]), let seconds=Double(t[2]) { duration=h*3600+m*60+seconds }
        var size: CGSize?
        if let dimensions = try groups(#"Video:[^\n]*? (\d{1,6})x(\d{1,6})(?:[ ,\[]|$)"#), let w=Double(dimensions[0]), let h=Double(dimensions[1]) {
            size=CGSize(width:w,height:h)
            if let rotation=try groups(#"rotation of (-?[0-9.]+) degrees"#), let angle=Double(rotation[0]), Int(abs(angle).rounded()) % 180 == 90 { size=CGSize(width:h,height:w) }
        }
        return MediaProbe(duration:duration,size:size)
    }

    @discardableResult private static func run(_ executable:URL,_ args:[String], acceptedStatuses: Set<Int32> = [0]) async throws -> String {
        return try await Task.detached(priority:.userInitiated) {
            let log=FileManager.default.temporaryDirectory.appendingPathComponent("local-tool-log-"+UUID().uuidString)
            guard FileManager.default.createFile(atPath:log.path,contents:nil) else {throw Failure("Could not create the process log.")}
            defer {try? FileManager.default.removeItem(at:log)}
            let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()}
            let process=Process();process.executableURL=executable;process.arguments=args;process.standardInput=FileHandle.nullDevice;process.standardOutput=handle;process.standardError=handle
            try process.run();process.waitUntilExit()
            let text=String(decoding:try Data(contentsOf:log),as:UTF8.self)
            guard acceptedStatuses.contains(process.terminationStatus) else {throw Failure(text.isEmpty ? "The media tool failed.":String(text.suffix(6000)))}
            return text
        }.value
    }
    private struct Failure: LocalizedError {let message:String;init(_ message:String){self.message=message};var errorDescription:String?{message}}
}
