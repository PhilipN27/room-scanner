import Foundation
import RoomScanCore
import XCTest
@testable import RoomScanStudio

/// Byte-level oracles for the schema-version-2 capture bundle: depth payload
/// packing/compression round-trips and manifest compatibility in both
/// directions. Only the live ARKit sceneDepth delivery needs the device gate.
final class RoomCaptureBundleDepthTests: XCTestCase {
    func testDepthPayloadRoundTripsThroughPackingAndCompression() {
        // A 4x3 float32 depth map stored with stride padding (5 pixels/row).
        let width = 4, height = 3, bytesPerPixel = 4, paddedPixelsPerRow = 5
        var values = [Float]()
        var padded = [Float](repeating: -1, count: paddedPixelsPerRow * height)
        for row in 0..<height {
            for column in 0..<width {
                let value = Float(row * width + column) * 0.25
                values.append(value)
                padded[row * paddedPixelsPerRow + column] = value
            }
        }

        let packed = padded.withUnsafeBytes { buffer in
            RoomCaptureBundleDepthCodec.packTightRows(
                base: buffer.baseAddress!,
                bytesPerRow: paddedPixelsPerRow * bytesPerPixel,
                width: width,
                height: height,
                bytesPerPixel: bytesPerPixel
            )
        }
        XCTAssertEqual(packed.count, width * height * bytesPerPixel)

        guard let compressed = RoomCaptureBundleDepthCodec.compress(packed) else {
            XCTFail("zlib compression failed")
            return
        }
        guard let decompressed = RoomCaptureBundleDepthCodec.decompress(
            compressed,
            expectedByteCount: packed.count
        ) else {
            XCTFail("zlib decompression failed")
            return
        }
        let decoded = decompressed.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
        XCTAssertEqual(decoded, values, "padding must be stripped and values preserved exactly")
    }

    func testConfidencePayloadRoundTripsAsUInt8() {
        let bytes: [UInt8] = [0, 1, 2, 2, 1, 0]
        let packed = bytes.withUnsafeBytes { buffer in
            RoomCaptureBundleDepthCodec.packTightRows(
                base: buffer.baseAddress!,
                bytesPerRow: 3,
                width: 3,
                height: 2,
                bytesPerPixel: 1
            )
        }
        guard
            let compressed = RoomCaptureBundleDepthCodec.compress(packed),
            let decompressed = RoomCaptureBundleDepthCodec.decompress(
                compressed,
                expectedByteCount: bytes.count
            )
        else {
            XCTFail("confidence payload round trip failed")
            return
        }
        XCTAssertEqual([UInt8](decompressed), bytes)
    }

    func testDecompressRejectsWrongExpectedByteCount() {
        let packed = Data([1, 2, 3, 4])
        guard let compressed = RoomCaptureBundleDepthCodec.compress(packed) else {
            XCTFail("zlib compression failed")
            return
        }
        XCTAssertNil(
            RoomCaptureBundleDepthCodec.decompress(compressed, expectedByteCount: 999),
            "a payload with the wrong decoded size must be rejected"
        )
    }

    /// A verbatim schema-version-1 manifest (no depth fields anywhere) must
    /// keep decoding with the version-2 model.
    func testVersionOneManifestStillDecodes() throws {
        let versionOneJSON = """
        {
          "schemaVersion" : 1,
          "createdAt" : "2026-08-10T18:00:00Z",
          "frames" : [
            {
              "fileName" : "frame-00001.jpg",
              "timestamp" : 12.5,
              "cameraTransform" : [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
              "intrinsics" : [100,0,0,0,100,0,320,240,1],
              "imageWidth" : 640,
              "imageHeight" : 480,
              "exposureDuration" : 0.008
            }
          ],
          "meshAnchorCount" : 1,
          "meshVertexCount" : 3,
          "meshFaceCount" : 1,
          "notes" : []
        }
        """
        let manifest = try RoomJSONCoding.makeDecoder().decode(
            RoomCaptureBundleManifest.self,
            from: Data(versionOneJSON.utf8)
        )
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.frames.count, 1)
        XCTAssertNil(manifest.frames[0].depth)
    }

    func testVersionTwoManifestRoundTripsDepthBlock() throws {
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            frames: [
                RoomCaptureBundleFrame(
                    fileName: "frame-00001.jpg",
                    timestamp: 1,
                    cameraTransform: Array(repeating: 0, count: 16),
                    intrinsics: Array(repeating: 0, count: 9),
                    imageWidth: 640,
                    imageHeight: 480,
                    exposureDuration: 0.008,
                    depth: RoomCaptureBundleFrameDepth(
                        fileName: "frame-00001-depth.bin",
                        confidenceFileName: "frame-00001-confidence.bin",
                        width: 256,
                        height: 192,
                        compression: RoomCaptureBundleDepthCodec.compressionName,
                        pixelFormat: RoomCaptureBundleDepthCodec.depthPixelFormatName
                    )
                )
            ],
            meshAnchorCount: 0,
            meshVertexCount: 0,
            meshFaceCount: 0,
            notes: []
        )
        XCTAssertEqual(RoomCaptureBundleManifest.currentSchemaVersion, 2)
        let encoded = try RoomJSONCoding.makeEncoder().encode(manifest)
        let decoded = try RoomJSONCoding.makeDecoder().decode(
            RoomCaptureBundleManifest.self,
            from: encoded
        )
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.frames[0].depth?.width, 256)
        XCTAssertEqual(decoded.frames[0].depth?.height, 192)
    }
}
