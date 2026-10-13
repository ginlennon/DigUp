import Foundation

/// PDFs of text pages, written by hand (PDF 1.4, Helvetica, one text stream per page), so tests make the same PDFs on
/// every platform: AppKit draws them only on a Mac.
enum TextPDF {
    /// One page per string (US Letter, 12 pt, wrapped at about 80 characters a line).
    static func write(_ pages: [String], to url: URL) throws {
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: String) {
            offsets.append(out.count)
            out += Data("\(offsets.count) 0 obj\n\(body)\nendobj\n".utf8)
        }
        // 1 the catalog, 2 the page tree, 3 the font; then each page (4, 6, …) and its contents (5, 7, …).
        object("<< /Type /Catalog /Pages 2 0 R >>")
        let kids = pages.indices.map { "\(4 + 2 * $0) 0 R" }.joined(separator: " ")
        object("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for (index, text) in pages.enumerated() {
            let lines = wrapped(text, width: 80).map { "(\(escaped($0))) Tj T*" }.joined(separator: "\n")
            let stream = "BT /F1 12 Tf 14 TL 60 720 Td\n\(lines)\nET"
            object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                   + "/Contents \(5 + 2 * index) 0 R >>")
            object("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        let table = out.count
        var tail = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { tail += String(format: "%010d 00000 n \n", offset) }
        tail += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        out += Data(tail.utf8)
        try out.write(to: url)
    }

    private static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        return line.isEmpty ? lines : lines + [line]
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}

#if canImport(Vision)
import CoreGraphics
import CoreText

/// A PDF whose one page is a picture of `text` and nothing else, as a scanner makes it (macOS: the scans' OCR).
enum ScannedPDF {
    static func write(_ text: String, to url: URL) throws {
        let width = 1240, height = 1754   // A4 at 150 dpi
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
        ]))
        bitmap.textPosition = CGPoint(x: 100, y: height - 200)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &page, nil) else { throw CocoaError(.fileWriteUnknown) }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: page)
        pdf.endPDFPage()
        pdf.closePDF()
    }
}
#elseif !canImport(ImageIO)
@testable import DigUpKit

/// A PDF whose one page is a picture of `text` and nothing else, as a scanner makes it (Linux, Windows: PDFium draws
/// `text` as `TextPDF` writes it, at 150 dpi, and the picture is all the new page holds).
enum ScannedPDF {
    static func write(_ text: String, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let page = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        let drawn = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        defer {
            try? FileManager.default.removeItem(at: page)
            try? FileManager.default.removeItem(at: drawn)
        }
        try TextPDF.write([text], to: page)
        try PDFExtractor.renderPage(1, of: page, pixels: 1650, to: drawn)   // US Letter at 150 dpi: 1275×1650
        guard let image = RGBImage.load(drawn.path) else { throw CocoaError(.fileWriteUnknown) }
        let gray = (0..<(image.width * image.height)).map { image.pixels[$0 * 3] }
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: String, stream: Data? = nil) {
            offsets.append(out.count)
            out += Data("\(offsets.count) 0 obj\n\(body)\n".utf8)
            if let stream { out += Data("stream\n".utf8) + stream + Data("\nendstream\n".utf8) }
            out += Data("endobj\n".utf8)
        }
        let draw = Data("q 612 0 0 792 0 0 cm /Scan Do Q".utf8)
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Scan 4 0 R >> >> "
               + "/Contents 5 0 R >>")
        object("<< /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /DeviceGray "
               + "/BitsPerComponent 8 /Length \(gray.count) >>", stream: Data(gray))
        object("<< /Length \(draw.count) >>", stream: draw)
        let table = out.count
        var tail = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { tail += String(format: "%010d 00000 n \n", offset) }
        tail += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        out += Data(tail.utf8)
        try out.write(to: url)
    }
}
#endif
