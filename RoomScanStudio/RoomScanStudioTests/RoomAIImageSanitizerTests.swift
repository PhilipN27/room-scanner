import CoreGraphics
import ImageIO
import RoomScanCore
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import RoomScanStudio

final class RoomAIImageSanitizerTests: XCTestCase {
    func testJPEGIsDecodedAndReencodedWithoutGPSOrPrivateMetadata() throws {
        let source = try makeImage(
            type: .jpeg,
            properties: [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 51.5074,
                    kCGImagePropertyGPSLongitude: -0.1278,
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "private-room-note",
                ],
            ]
        )

        let result = try RoomAIImageSanitizer.sanitize(
            source,
            declaredFilename: "reference.jpg"
        )

        XCTAssertEqual(result.mediaType, "image/jpeg")
        XCTAssertEqual(result.pixelWidth, 2)
        XCTAssertEqual(result.pixelHeight, 2)
        XCTAssertEqual(result.data.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(result.data.suffix(2), Data([0xFF, 0xD9]))
        XCTAssertFalse(result.data.contains(Data("private-room-note".utf8)))
        let properties = try outputProperties(result.data)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyOrientation])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertNoThrow(try RoomConceptImageValidator.validateSanitizedImage(
            result.data,
            mediaType: result.mediaType
        ))
    }

    func testPNGAncillaryMetadataIsRemovedAndIENDIsTerminal() throws {
        let source = try makeImage(
            type: .png,
            properties: [kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: "private-xmp-like-note",
            ]]
        )

        let result = try RoomAIImageSanitizer.sanitize(
            source,
            declaredFilename: "reference.png"
        )

        XCTAssertEqual(result.mediaType, "image/png")
        XCTAssertFalse(result.data.contains(Data("private-xmp-like-note".utf8)))
        XCTAssertNoThrow(try RoomAIImageSanitizer.validateSanitizedBytes(
            result.data,
            mediaType: result.mediaType
        ))
        XCTAssertEqual(result.data.suffix(12), Data([
            0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ]))
    }

    func testTrailingPayloadAndMislabeledMediaFailClosed() throws {
        var trailingJPEG = try makeImage(type: .jpeg)
        trailingJPEG.append(Data("<script>exfiltrate()</script>".utf8))

        XCTAssertThrowsError(try RoomAIImageSanitizer.sanitize(
            trailingJPEG,
            declaredFilename: "reference.jpg"
        )) { error in
            XCTAssertEqual(error as? RoomAIImageSanitizationError, .trailingPayload)
        }

        let png = try makeImage(type: .png)
        XCTAssertThrowsError(try RoomAIImageSanitizer.sanitize(
            png,
            declaredFilename: "reference.jpg"
        )) { error in
            XCTAssertEqual(error as? RoomAIImageSanitizationError, .declaredTypeMismatch)
        }
    }

    func testActiveUnsupportedAndPolyglotInputsFailClosed() throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>".utf8)
        XCTAssertThrowsError(try RoomAIImageSanitizer.sanitize(
            svg,
            declaredFilename: "concept.svg"
        )) { error in
            XCTAssertEqual(error as? RoomAIImageSanitizationError, .unsupportedMedia)
        }

        var polyglot = try makeImage(type: .png)
        polyglot.append(Data("PK\u{3}\u{4}nested.zip".utf8))
        XCTAssertThrowsError(try RoomAIImageSanitizer.sanitize(
            polyglot,
            declaredFilename: "concept.png"
        )) { error in
            XCTAssertEqual(error as? RoomAIImageSanitizationError, .trailingPayload)
        }
    }

    func testPixelAndByteBudgetsAreCheckedBeforePublication() throws {
        let png = try makeImage(type: .png)
        XCTAssertThrowsError(try RoomAIImageSanitizer.sanitize(
            png,
            declaredFilename: "concept.png",
            limits: .init(maximumInputBytes: 8, maximumDimension: 8_192, maximumPixels: 24_000_000)
        )) { error in
            XCTAssertEqual(error as? RoomAIImageSanitizationError, .inputTooLarge)
        }
    }

    func testReferenceBoundaryNormalizesPNGToMetadataFreeJPEG() throws {
        let png = try makeImage(
            type: .png,
            properties: [kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: "private-reference-note",
            ]]
        )

        let result = try RoomAIImageSanitizer.sanitizeReferenceJPEG(
            png,
            declaredFilename: "replacement.png"
        )

        XCTAssertEqual(result.mediaType, "image/jpeg")
        XCTAssertFalse(result.data.contains(Data("private-reference-note".utf8)))
        XCTAssertNoThrow(try RoomConceptImageValidator.validateSanitizedImage(
            result.data,
            mediaType: result.mediaType
        ))
    }

    func testReviewThumbnailIsBoundedDecodableAndMetadataFree() throws {
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 1_600, height: 1_000)
        ).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_000))
            UIColor.white.setFill()
            context.fill(CGRect(x: 260, y: 180, width: 1_080, height: 640))
        }
        let sanitized = try RoomAIImageSanitizer.sanitize(
            source,
            declaredFilename: "review.jpg"
        )

        let thumbnail = try RoomAIImageSanitizer.makeReviewThumbnailJPEG(
            sanitized.data
        )

        XCTAssertLessThanOrEqual(
            thumbnail.count,
            RoomAIImageSanitizer.maximumReviewThumbnailBytes
        )
        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(thumbnail as CFData, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        )
        XCTAssertLessThanOrEqual(
            max(image.width, image.height),
            RoomAIImageSanitizer.maximumReviewThumbnailDimension
        )
        XCTAssertNoThrow(try RoomConceptImageValidator.validateSanitizedImage(
            thumbnail,
            mediaType: "image/jpeg"
        ))
    }

    private enum FixtureType {
        case jpeg
        case png

        var identifier: CFString {
            switch self {
            case .jpeg: UTType.jpeg.identifier as CFString
            case .png: UTType.png.identifier as CFString
            }
        }
    }

    private func makeImage(
        type: FixtureType,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let pixels: [UInt8] = [
            220, 40, 30, 255, 20, 180, 80, 255,
            40, 80, 220, 255, 240, 210, 30, 255,
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            type.identifier,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func outputProperties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }
}
