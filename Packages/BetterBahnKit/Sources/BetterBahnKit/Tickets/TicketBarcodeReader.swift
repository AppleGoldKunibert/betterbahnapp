#if canImport(PDFKit) && canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Finds the Aztec code on a ticket PDF from bahn.de.
///
/// The code is only printed on the PDF, so the page is rendered and scanned. The bytes are taken
/// over exactly as they are (a signed UIC ticket barcode) – generating a new code from the ticket's
/// details would never pass a check.
public enum TicketBarcodeReader {
    /// Rendering scale: DB's Aztec codes are about 5 cm wide, which gives Vision enough pixels per module.
    static let scale: CGFloat = 4

    public static func barcode(inPDF data: Data) -> DBTicket.Barcode? {
        guard let document = PDFDocument(data: data) else { return nil }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = render(page) else { continue }
            if let barcode = barcode(in: image) { return barcode }
        }
        return nil
    }

    /// The code on a photo or screenshot, e.g. of a Deutschland-Ticket in DB Navigator.
    public static func barcode(inImage data: Data) -> DBTicket.Barcode? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return barcode(in: image)
    }

    static func barcode(in image: CGImage) -> DBTicket.Barcode? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.aztec]
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        return DBTicket.Barcode(payload: observation.payloadStringValue.flatMap(bytes),
                                image: crop(image, to: observation.boundingBox))
    }

    /// Vision's `payloadData` is Aztec's internal encoding, not the message. The decoded string maps
    /// each byte to one ISO-8859-1 character (Aztec's default), so the bytes come back one to one;
    /// anything outside that range means it wasn't read as bytes, and nothing is returned.
    static func bytes(_ string: String) -> Data? {
        var data = Data(capacity: string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            guard scalar.value < 256 else { return nil }
            data.append(UInt8(scalar.value))
        }
        return data.isEmpty ? nil : data
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// The code plus a quiet zone, as PNG. `box` is Vision's normalized rect (origin bottom left).
    static func crop(_ image: CGImage, to box: CGRect) -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        rect = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.1).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = image.cropping(to: rect) else { return nil }
        return png(cropped)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
