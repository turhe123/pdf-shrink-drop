import AppKit
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Errors surfaced to the file list.
enum CompressError: LocalizedError {
    case unreadable, locked, writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Not a readable PDF"
        case .locked: return "Wrong or missing password"
        case .writeFailed: return "Could not write the output file"
        }
    }
}

/// Stateless PDF shrinking engine. Runs off the main thread and writes to a caller-supplied temp file.
enum Compressor {
    /// Compresses `input` into `output`. Checks `Task.isCancelled` between pages.
    static func compress(_ input: URL, to output: URL, password: String?,
                         settings: CompressionSettings, progress: @escaping (Double) -> Void) throws {
        guard let doc = PDFDocument(url: input) else { throw CompressError.unreadable }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else { throw CompressError.locked }
        }
        try Task.checkCancellation()
        if settings.useQuartzFilter, !doc.isEncrypted, writeWithQuartzFilter(doc, to: output, settings: settings) {
            progress(1)
            return
        }
        try Task.checkCancellation()
        try rewritePageByPage(doc, source: input, to: output, settings: settings, progress: progress)
    }

    // MARK: Quartz filter route

    /// Builds a "Reduce File Size"-style filter from our settings and writes the document through it.
    private static func writeWithQuartzFilter(_ doc: PDFDocument, to output: URL, settings: CompressionSettings) -> Bool {
        let properties: [String: Any] = [
            "Name": "PdfShrinkDrop",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": settings.quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageScaleFactor": 1.0,
                            "ImageSizeMax": settings.maxDimension,
                            "ImageSizeMin": 128,
                            "Interpolation Quality": 0.6,
                        ],
                    ],
                ],
            ],
        ]
        guard let filter = QuartzFilter(properties: properties) else { return false }
        let option = PDFDocumentWriteOption(rawValue: "QuartzFilter")
        return doc.write(to: output, withOptions: [option: filter])
    }

    // MARK: Page-by-page route

    /// Copies text/vector pages as vectors and re-renders image-heavy pages as downsampled JPEGs.
    private static func rewritePageByPage(_ doc: PDFDocument, source: URL, to output: URL,
                                          settings: CompressionSettings, progress: @escaping (Double) -> Void) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, metadata(of: doc) as CFDictionary)
        else { throw CompressError.writeFailed }

        let count = max(doc.pageCount, 1)
        let fileSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let averagePageBytes = fileSize / count

        for index in 0..<doc.pageCount {
            if Task.isCancelled { ctx.closePDF(); throw CancellationError() }
            autoreleasepool {
                guard let page = doc.page(at: index) else { return }
                var box = CGRect(origin: .zero, size: displaySize(of: page))
                ctx.beginPage(mediaBox: &box)
                if averagePageBytes > 60_000, let image = rasterIfSmaller(page, size: box.size, settings: settings) {
                    ctx.draw(image, in: box)
                } else {
                    page.draw(with: .cropBox, to: ctx)
                }
                ctx.endPage()
            }
            progress(Double(index + 1) / Double(count))
        }
        ctx.closePDF()
    }

    /// Returns a JPEG-backed image for the page when it is image-heavy and the JPEG beats its current size.
    private static func rasterIfSmaller(_ page: PDFPage, size: CGSize, settings: CompressionSettings) -> CGImage? {
        // Keep text-rich pages as vectors so they stay sharp and searchable.
        if (page.string ?? "").count > 1200 { return nil }
        let pageBytes = estimatedBytes(of: page)
        guard pageBytes > 120_000 else { return nil }

        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = CGFloat(settings.maxDimension) / longest
        let width = max(Int(size.width * scale), 1), height = max(Int(size.height * scale), 1)
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.interpolationQuality = .high
        bitmap.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: bitmap)
        guard let rendered = bitmap.makeImage(), let jpeg = jpegData(rendered, quality: settings.quality),
              jpeg.count < pageBytes * 7 / 10,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Size of the page when saved on its own — a proxy for how much image data it carries.
    private static func estimatedBytes(of page: PDFPage) -> Int {
        guard let copy = page.copy() as? PDFPage else { return 0 }
        let single = PDFDocument()
        single.insert(copy, at: 0)
        return single.dataRepresentation()?.count ?? 0
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func displaySize(of page: PDFPage) -> CGSize {
        let rect = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
    }

    /// Carries title, author and friends over to the new file.
    private static func metadata(of doc: PDFDocument) -> [CFString: Any] {
        let attrs = doc.documentAttributes ?? [:]
        let map: [(PDFDocumentAttribute, CFString)] = [
            (.titleAttribute, kCGPDFContextTitle), (.authorAttribute, kCGPDFContextAuthor),
            (.subjectAttribute, kCGPDFContextSubject), (.creatorAttribute, kCGPDFContextCreator),
        ]
        var info: [CFString: Any] = [:]
        for (key, cgKey) in map { if let value = attrs[key] as? String { info[cgKey] = value } }
        if let keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            info[kCGPDFContextKeywords] = keywords.joined(separator: ", ")
        }
        return info
    }

    // MARK: Merge

    /// Joins the given PDFs, in order, into `output`.
    static func merge(_ inputs: [(url: URL, password: String?)], to output: URL) throws {
        let merged = PDFDocument()
        for input in inputs {
            try Task.checkCancellation()
            guard let doc = PDFDocument(url: input.url) else { continue }
            if doc.isLocked, !(input.password.map { doc.unlock(withPassword: $0) } ?? false) { continue }
            for index in 0..<doc.pageCount {
                if let page = doc.page(at: index)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0, merged.write(to: output) else { throw CompressError.writeFailed }
    }

    // MARK: File placement

    /// Where the result for `original` should land.
    static func destination(for original: URL, folderPath: String, replace: Bool) -> URL {
        if replace { return original }
        let folder = folderPath.isEmpty ? original.deletingLastPathComponent()
                                        : URL(fileURLWithPath: folderPath, isDirectory: true)
        let name = original.deletingPathExtension().lastPathComponent + "-shrunk"
        return folder.appendingPathComponent(name).appendingPathExtension("pdf")
    }

    /// A scratch directory on the same volume as `destination`, so the final move is atomic.
    static func scratchDirectory(near destination: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination, create: true)
    }

    /// Moves `temp` into place. When replacing, the original goes to the Trash first.
    static func install(_ temp: URL, at destination: URL, replacingOriginal: Bool) throws {
        let fm = FileManager.default
        if replacingOriginal {
            try fm.trashItem(at: destination, resultingItemURL: nil)
            try fm.moveItem(at: temp, to: destination)
        } else if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }
}
