import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Orra

/// Images and PDFs with drawn text for the tests of text recognition, made at test time, so
/// no real document or photo is needed.
enum RecognitionTestFiles {
    /// Why a file could not be made.
    struct Failure: Error {}

    /// A stand in for text recognition that finds no text and leaves no page, for the tests
    /// that index folders without images or scans, so no test but VisionTextRecognitionTests
    /// and the opt in measurement runs Vision.
    static let findsNothing: FolderIndex.Recognize = { _, _ in .success(RecognitionResult(isDone: true)) }

    /// An image of lines drawn with CoreText at `points` pixels, `ink` on `paper` in gray, 0
    /// black and 1 white, one line every 1.5 lines from the top left, turned `degrees`
    /// counterclockwise about the image's center. A line in Chinese takes PingFang SC, any
    /// other Helvetica.
    static func image(
        _ lines: [String], width: Int = 1_200, height: Int = 300, points: CGFloat = 48, ink: CGFloat = 0, paper: CGFloat = 1,
        degrees: CGFloat = 0
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw Failure() }
        context.setFillColor(gray: paper, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if degrees != 0 {
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: degrees * .pi / 180)
            context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        }
        var baseline = CGFloat(height) - points * 1.5
        for line in lines {
            draw(line, at: CGPoint(x: points, y: baseline), points: points, gray: ink, in: context)
            baseline -= points * 1.5
        }
        guard let image = context.makeImage() else { throw Failure() }
        return image
    }

    /// Draws a line of text, in PingFang SC when it holds Chinese and Helvetica otherwise.
    static func draw(_ line: String, at point: CGPoint, points: CGFloat, gray: CGFloat, in context: CGContext) {
        let chinese = line.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let font = CTFontCreateWithName((chinese ? "PingFang SC" : "Helvetica") as CFString, points, nil)
        let color = CGColor(gray: gray, alpha: 1)
        let text = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        context.textPosition = point
        CTLineDraw(text, context)
    }

    /// The images in a file of `type`, one frame or page each, as ImageIO writes it.
    static func data(_ images: [CGImage], type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil) else { throw Failure() }
        for image in images {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
        return data as Data
    }

    /// A page of a PDF.
    enum Page {
        /// Lines of real text, 14 points, which give the page a text layer.
        case text([String])
        /// A picture of a page without a text layer, as a scanner makes it.
        case scan(CGImage)
        /// A black square at the page's top left corner, without text.
        case mark
    }

    /// A US letter PDF of the pages, turned `rotation` degrees clockwise as a reader shows it.
    static func pdf(_ pages: [Page], rotation: Int = 0) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure() }
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let lines):
                var baseline: CGFloat = 720
                for line in lines {
                    draw(line, at: CGPoint(x: 72, y: baseline), points: 14, gray: 0, in: context)
                    baseline -= 24
                }
            case .scan(let image):
                context.draw(image, in: box)
            case .mark:
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 692, width: 100, height: 100))
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard rotation != 0 else { return data as Data }
        guard let document = PDFDocument(data: data as Data) else { throw Failure() }
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation = rotation
        }
        guard let turned = document.dataRepresentation() else { throw Failure() }
        return turned
    }

    /// The gray level of each pixel of an image, the first row at the top.
    static func grayPixels(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw Failure() }
        return pixels
    }
}
