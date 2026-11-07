import CoreImage
import ImageIO
import XCTest
@testable import DateGuesser

final class PhotoRotatorTests: XCTestCase {
    func testDegreesSnapToQuarterTurns() {
        XCTAssertEqual(Rotation(degrees: 90), .clockwise90)
        XCTAssertEqual(Rotation(degrees: 450), .clockwise90)
        XCTAssertEqual(Rotation(degrees: -90), .clockwise270)
        XCTAssertEqual(Rotation.clockwise90.inverse, .clockwise270)
    }

    /// A wide image whose left half is red: after a clockwise turn it's tall, with red on top.
    func testClockwiseTurnPutsTheLeftSideOnTop() throws {
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 2, y: 0, width: 2, height: 2))
        let image = red.composited(over: blue)
        let rotated = PhotoRotator.rotatedImage(image, exifOrientation: 1, by: .clockwise90)
        XCTAssertEqual(rotated.extent, CGRect(x: 0, y: 0, width: 2, height: 4))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext()
        // Core Image's y axis points up, so the top row is at y = 3.
        context.render(rotated, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 3, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        XCTAssertGreaterThan(pixel[0], 200, "top should be red, got \(pixel)")
        XCTAssertLessThan(pixel[2], 50)
    }

    func testMetadataIsUprightWithNewSize() {
        let source: [CFString: Any] = [
            kCGImagePropertyOrientation: 6, kCGImagePropertyPixelWidth: 4000,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFMake: "Canon"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 4000, kCGImagePropertyExifDateTimeOriginal: "2003:11:01 12:00:00"],
        ]
        let out = PhotoRotator.metadata(source, width: 3000, height: 4000)
        XCTAssertEqual(out[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertNil(out[kCGImagePropertyPixelWidth])
        let tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation] as? Int, 1)
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Canon")
        let exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension] as? Int, 3000)
        // The capture date is kept.
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2003:11:01 12:00:00")
    }
}
