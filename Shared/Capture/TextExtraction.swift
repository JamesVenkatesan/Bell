import Foundation
import PDFKit
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// Gets positioned text out of whatever the user hands over.
///
/// The important word is *positioned*. A timetable is a table, and flattening
/// a table into lines destroys the column that says which day a class is on.
/// Read as lines, a schedule grid becomes rows like
/// "ECE 30100 Lec  ECE 30100 Lec" — two different days, one string, and
/// nothing downstream can recover which is which.
///
/// So everything here keeps each fragment's position, and the readers that
/// consume it work in two dimensions.
enum TextExtraction {

    /// A positioned piece of text: a word from a PDF, a line from Vision.
    struct Fragment: Hashable {
        var text: String
        /// Normalised 0…1, origin top-left, so PDF and image sources are
        /// directly comparable.
        var frame: CGRect
        var confidence: Double

        var midX: CGFloat { frame.midX }
        var midY: CGFloat { frame.midY }
        var left: CGFloat { frame.minX }
    }

    struct Page {
        var fragments: [Fragment]
        var index: Int

        /// The source's own text, when it has one.
        ///
        /// PDFKit knows exactly where its words begin and end; rebuilding them
        /// from character boxes guesses, and a guess that splits "ECE" into
        /// "E" and "CE" destroys the token the whole reader anchors on. When
        /// the source can tell us the text, we believe it, and geometry is
        /// kept only for the readers that genuinely need positions.
        var rawText: String? = nil

        /// Fragments grouped into visual rows, each sorted left to right.
        func rows(tolerance: CGFloat = 0.008) -> [[Fragment]] {
            let sorted = fragments.sorted { $0.midY < $1.midY }
            var rows: [[Fragment]] = []

            for fragment in sorted {
                if let reference = rows.last?.first,
                   abs(reference.midY - fragment.midY) < tolerance {
                    rows[rows.count - 1].append(fragment)
                } else {
                    rows.append([fragment])
                }
            }

            return rows.map { $0.sorted { $0.left < $1.left } }
        }

        /// What the token-based readers parse.
        ///
        /// A registrar table rebuilt by position comes first: PDFKit's own
        /// string emits that table in column blocks, which is how every PDF
        /// import lost its rooms and instructors.
        var plainText: String {
            if let table = TableLayout.reflow(fragments) { return table }
            if let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rawText
            }
            return rows().map { $0.map(\.text).joined(separator: "  ") }
                .joined(separator: "\n")
        }
    }

    enum ExtractionError: LocalizedError {
        case unreadable
        case noTextFound
        case unsupportedType(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "That file couldn't be opened."
            case .noTextFound:
                "No text found. If it's a photo, try again with the schedule filling the frame and the page flat."
            case .unsupportedType(let ext):
                "Bell can't read .\(ext) files. A PDF, photo or screenshot works."
            }
        }
    }

    // MARK: - Entry point

    static func pages(from url: URL) async throws -> [Page] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        switch url.pathExtension.lowercased() {
        case "pdf":
            return try await fromPDF(url)
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "webp":
            guard let data = try? Data(contentsOf: url) else { throw ExtractionError.unreadable }
            return [try await fromImageData(data)]
        case let other:
            throw ExtractionError.unsupportedType(other)
        }
    }

    // MARK: - PDF

    private static func fromPDF(_ url: URL) async throws -> [Page] {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable }

        var pages: [Page] = []

        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }

            let text = page.string ?? ""
            let words = lineFragments(from: page)

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(Page(fragments: words, index: index, rawText: text))
            } else if let rendered = rasterise(page) {
                // Scanned, or a text layer that isn't really there.
                var ocr = try await fromImageData(rendered)
                ocr.index = index
                pages.append(ocr)
            }
        }

        guard pages.contains(where: { !$0.fragments.isEmpty }) else {
            throw ExtractionError.noTextFound
        }
        return pages
    }

    /// One fragment per line of text, with that line's own bounds.
    ///
    /// This replaced a word builder that paired `page.string`'s characters
    /// with `characterBounds(at:)` by index. The two don't correspond one to
    /// one (the string contains characters with no box), so every position
    /// after the first mismatch drifted: words came out cut ("Rei" / "bman,")
    /// and placed in the wrong cell. That drift, not PDFKit, is why
    /// geometry-based reading was abandoned before.
    ///
    /// Line selections carry their text and their bounds together, so they
    /// can't drift. In a table a line is a cell (or one line of a wrapped
    /// cell), which is also what Vision returns for an image.
    static func lineFragments(from page: PDFPage) -> [Fragment] {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0,
              let lines = page.selection(for: bounds)?.selectionsByLine() else { return [] }

        return lines.compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = line.bounds(for: page)
            // PDF origin is bottom-left; normalise to top-left.
            return Fragment(text: text,
                            frame: CGRect(x: (box.minX - bounds.minX) / bounds.width,
                                          y: 1 - (box.maxY - bounds.minY) / bounds.height,
                                          width: box.width / bounds.width,
                                          height: box.height / bounds.height),
                            confidence: 1)
        }
    }

    private static func rasterise(_ page: PDFPage) -> Data? {
        #if canImport(UIKit)
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }.pngData()
        #else
        return nil
        #endif
    }

    // MARK: - Images

    static func fromImageData(_ data: Data) async throws -> Page {
        #if canImport(UIKit)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw ExtractionError.unreadable
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Course codes and room numbers aren't dictionary words, and language
        // correction turns "BHEE" into "THREE" often enough to matter.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        // Timetable grids set small type; this stops Vision discarding it.
        request.minimumTextHeight = 0.005

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw ExtractionError.noTextFound
        }

        // Vision returns one observation per visual line, which in a grid is
        // usually one cell — already the granularity the readers want.
        let fragments: [Fragment] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Fragment(
                text: candidate.string,
                frame: CGRect(x: box.minX, y: 1 - box.maxY,
                              width: box.width, height: box.height),
                confidence: Double(candidate.confidence))
        }

        return Page(fragments: fragments, index: 0)
        #else
        throw ExtractionError.unsupportedType("image")
        #endif
    }
}
