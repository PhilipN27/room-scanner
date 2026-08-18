import CoreGraphics
import Foundation
import ImageIO
import RoomScanCore
import UniformTypeIdentifiers

enum RoomAIImageSanitizationError: Error, Equatable {
    case emptyInput
    case inputTooLarge
    case unsupportedMedia
    case declaredTypeMismatch
    case malformedImage
    case multipleImages
    case imageDimensionsOutOfBounds
    case trailingPayload
    case reencodingFailed
}

struct RoomAIImageSanitizationLimits: Sendable, Equatable {
    static let `default` = RoomAIImageSanitizationLimits(
        maximumInputBytes: 32 * 1_024 * 1_024,
        maximumDimension: 8_192,
        maximumPixels: 24_000_000
    )

    var maximumInputBytes: Int
    var maximumDimension: Int
    var maximumPixels: Int

    init(maximumInputBytes: Int, maximumDimension: Int, maximumPixels: Int) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumDimension = maximumDimension
        self.maximumPixels = maximumPixels
    }

    fileprivate func validate() throws {
        guard maximumInputBytes > 0, maximumDimension > 0, maximumPixels > 0 else {
            throw RoomAIImageSanitizationError.imageDimensionsOutOfBounds
        }
    }
}

struct RoomAISanitizedImage: Sendable, Equatable {
    let data: Data
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// A positive-list outbound media boundary. Source bytes are never copied into
/// an AI package or Concept Set: one complete JPEG/PNG is decoded, orientation
/// is applied, and a fresh sRGB raster is emitted without source metadata.
enum RoomAIImageSanitizer {
    static let maximumReviewThumbnailDimension = 720
    static let maximumReviewThumbnailBytes = 1_000_000

    static func sanitize(
        _ data: Data,
        declaredFilename: String? = nil,
        limits: RoomAIImageSanitizationLimits = .default
    ) throws -> RoomAISanitizedImage {
        try limits.validate()
        guard !data.isEmpty else { throw RoomAIImageSanitizationError.emptyInput }
        guard data.count <= limits.maximumInputBytes else {
            throw RoomAIImageSanitizationError.inputTooLarge
        }

        let format = try sniffAndValidateFraming(data)
        if let declaredFilename {
            let declaredExtension = URL(fileURLWithPath: declaredFilename)
                .pathExtension
                .lowercased()
            guard format.acceptedExtensions.contains(declaredExtension) else {
                throw RoomAIImageSanitizationError.declaredTypeMismatch
            }
        }

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw RoomAIImageSanitizationError.malformedImage
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw RoomAIImageSanitizationError.multipleImages
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw RoomAIImageSanitizationError.malformedImage
        }
        guard let sourceType = CGImageSourceGetType(source) as String?,
              format.matches(typeIdentifier: sourceType)
        else {
            throw RoomAIImageSanitizationError.unsupportedMedia
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= limits.maximumDimension,
              height <= limits.maximumDimension,
              width <= limits.maximumPixels / height
        else {
            throw RoomAIImageSanitizationError.imageDimensionsOutOfBounds
        }

        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            decodeOptions as CFDictionary
        ) else {
            throw RoomAIImageSanitizationError.malformedImage
        }
        guard decoded.width > 0,
              decoded.height > 0,
              decoded.width <= limits.maximumDimension,
              decoded.height <= limits.maximumDimension,
              decoded.width <= limits.maximumPixels / decoded.height
        else {
            throw RoomAIImageSanitizationError.imageDimensionsOutOfBounds
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        let outputProperties: [CFString: Any]
        switch format {
        case .jpeg:
            outputProperties = [
                kCGImageDestinationLossyCompressionQuality: 0.92,
            ]
        case .png:
            outputProperties = [:]
        }
        CGImageDestinationAddImage(destination, decoded, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        let sanitized = try stripOutputMetadata(output as Data, format: format)
        guard !sanitized.isEmpty, sanitized.count <= limits.maximumInputBytes else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        try validateSanitizedBytes(sanitized, mediaType: format.mediaType)
        return RoomAISanitizedImage(
            data: sanitized,
            mediaType: format.mediaType,
            pixelWidth: decoded.width,
            pixelHeight: decoded.height
        )
    }

    /// Selected AI-package references have one portable media contract:
    /// baseline JPEG. PNG remains a supported input, but its decoded pixels
    /// cross the same fresh-encode and metadata-strip boundary before use.
    static func sanitizeReferenceJPEG(
        _ data: Data,
        declaredFilename: String,
        limits: RoomAIImageSanitizationLimits = .default
    ) throws -> RoomAISanitizedImage {
        let firstPass = try sanitize(
            data,
            declaredFilename: declaredFilename,
            limits: limits
        )
        if firstPass.mediaType == "image/jpeg" { return firstPass }
        guard let source = CGImageSourceCreateWithData(firstPass.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RoomAIImageSanitizationError.malformedImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw RoomAIImageSanitizationError.reencodingFailed }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        let jpeg = try stripJPEGMetadata(output as Data)
        try validateSanitizedBytes(jpeg, mediaType: "image/jpeg")
        return .init(
            data: jpeg,
            mediaType: "image/jpeg",
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Produces a small, metadata-free display derivative from bytes that
    /// already passed the outbound sanitizer. Review UI never decodes a full
    /// capture image on the main actor or retains its original metadata.
    static func makeReviewThumbnailJPEG(_ data: Data) throws -> Data {
        let format = try sniffAndValidateFraming(data)
        try validateSanitizedBytes(data, mediaType: format.mediaType)
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            CGImageSourceGetCount(source) == 1,
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumReviewThumbnailDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        else {
            throw RoomAIImageSanitizationError.malformedImage
        }
        guard thumbnail.width > 0,
              thumbnail.height > 0,
              thumbnail.width <= maximumReviewThumbnailDimension,
              thumbnail.height <= maximumReviewThumbnailDimension
        else {
            throw RoomAIImageSanitizationError.imageDimensionsOutOfBounds
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        let result = try stripJPEGMetadata(output as Data)
        guard !result.isEmpty, result.count <= maximumReviewThumbnailBytes else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        try validateSanitizedBytes(result, mediaType: "image/jpeg")
        return result
    }

    static func validateSanitizedBytes(_ data: Data, mediaType: String) throws {
        let format = try sniffAndValidateFraming(data)
        guard format.mediaType == mediaType else {
            throw RoomAIImageSanitizationError.declaredTypeMismatch
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let type = CGImageSourceGetType(source) as String?,
            format.matches(typeIdentifier: type)
        else {
            throw RoomAIImageSanitizationError.malformedImage
        }
        // Core's byte parser is intentionally stricter than ImageIO. It
        // rejects EXIF/XMP/comment segments and metadata/animation chunks that
        // ImageIO may emit even after a fresh encode. Keep that portable
        // contract at the common sanitizer boundary for every outbound path.
        do {
            _ = try RoomConceptImageValidator.validateSanitizedImage(
                data,
                mediaType: mediaType
            )
        } catch {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
    }

    private enum Format {
        case jpeg
        case png

        var mediaType: String {
            switch self {
            case .jpeg: "image/jpeg"
            case .png: "image/png"
            }
        }

        var typeIdentifier: String {
            switch self {
            case .jpeg: UTType.jpeg.identifier
            case .png: UTType.png.identifier
            }
        }

        var acceptedExtensions: Set<String> {
            switch self {
            case .jpeg: ["jpg", "jpeg"]
            case .png: ["png"]
            }
        }

        func matches(typeIdentifier value: String) -> Bool {
            value == typeIdentifier
        }
    }

    private static func sniffAndValidateFraming(_ data: Data) throws -> Format {
        if data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 {
            guard data[data.count - 2] == 0xFF, data[data.count - 1] == 0xD9 else {
                throw RoomAIImageSanitizationError.trailingPayload
            }
            return .jpeg
        }
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if data.starts(with: pngSignature) {
            try validatePNGChunks(data)
            return .png
        }
        throw RoomAIImageSanitizationError.unsupportedMedia
    }

    /// ImageIO currently emits a normalized orientation record even when the
    /// input raster has already been transformed. Remove whole metadata
    /// segments/chunks from the newly encoded payload, then let both ImageIO
    /// and Core validate the resulting portable framing.
    private static func stripOutputMetadata(
        _ data: Data,
        format: Format
    ) throws -> Data {
        switch format {
        case .jpeg:
            return try stripJPEGMetadata(data)
        case .png:
            return try stripPNGMetadata(data)
        }
    }

    private static func stripJPEGMetadata(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        var output = Data(bytes[0..<2])
        var offset = 2
        let forbiddenMarkers: Set<UInt8> = [0xE1, 0xE2, 0xED, 0xFE]
        while offset < bytes.count {
            let markerStart = offset
            guard bytes[offset] == 0xFF else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
            guard offset < bytes.count else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xD9 {
                output.append(contentsOf: bytes[markerStart..<offset])
                guard offset == bytes.count else {
                    throw RoomAIImageSanitizationError.reencodingFailed
                }
                return output
            }
            guard marker != 0xD8,
                  marker != 0x01,
                  !(0xD0...0xD7).contains(marker),
                  offset <= bytes.count - 2
            else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            let segmentEnd = offset + length
            if marker == 0xDA {
                output.append(contentsOf: bytes[markerStart..<bytes.count])
                return output
            }
            if !forbiddenMarkers.contains(marker) {
                output.append(contentsOf: bytes[markerStart..<segmentEnd])
            }
            offset = segmentEnd
        }
        throw RoomAIImageSanitizationError.reencodingFailed
    }

    private static func stripPNGMetadata(_ data: Data) throws -> Data {
        let signatureLength = 8
        guard data.count >= signatureLength else {
            throw RoomAIImageSanitizationError.reencodingFailed
        }
        var output = Data(data.prefix(signatureLength))
        var offset = signatureLength
        let allowedChunks: Set<String> = [
            "IHDR", "PLTE", "IDAT", "IEND", "tRNS",
            "sRGB", "gAMA", "cHRM", "iCCP",
        ]
        while offset < data.count {
            guard data.count - offset >= 12 else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            let length = Int(readBigEndianUInt32(data, offset: offset))
            guard length <= data.count - offset - 12 else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            let typeRange = (offset + 4)..<(offset + 8)
            guard let type = String(bytes: data[typeRange], encoding: .ascii) else {
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            let chunkEnd = offset + 12 + length
            if allowedChunks.contains(type) {
                output.append(data[offset..<chunkEnd])
            } else if data[offset + 4] & 0x20 == 0 {
                // Never silently discard an unknown critical chunk.
                throw RoomAIImageSanitizationError.reencodingFailed
            }
            offset = chunkEnd
        }
        return output
    }

    private static func validatePNGChunks(_ data: Data) throws {
        var offset = 8
        var sawHeader = false
        var sawImageEnd = false
        while offset < data.count {
            guard data.count - offset >= 12 else {
                throw RoomAIImageSanitizationError.malformedImage
            }
            let length = Int(readBigEndianUInt32(data, offset: offset))
            guard length <= data.count - offset - 12 else {
                throw RoomAIImageSanitizationError.malformedImage
            }
            let typeOffset = offset + 4
            let type = String(bytes: data[typeOffset..<(typeOffset + 4)], encoding: .ascii)
            guard let type else { throw RoomAIImageSanitizationError.malformedImage }
            if !sawHeader {
                guard type == "IHDR", length == 13 else {
                    throw RoomAIImageSanitizationError.malformedImage
                }
                sawHeader = true
            }
            let next = offset + 12 + length
            if type == "IEND" {
                guard length == 0 else {
                    throw RoomAIImageSanitizationError.malformedImage
                }
                guard next == data.count else {
                    throw RoomAIImageSanitizationError.trailingPayload
                }
                sawImageEnd = true
            } else if sawImageEnd {
                throw RoomAIImageSanitizationError.trailingPayload
            }
            offset = next
        }
        guard sawHeader, sawImageEnd, offset == data.count else {
            throw RoomAIImageSanitizationError.malformedImage
        }
    }

    private static func readBigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}
