import XCTest
@testable import RoomScanCore

final class RoomMeshFrameAnalysisTests: XCTestCase {
    func testEveryEncodedSRGBByteMatchesTheExplicitTransferFunction() {
        for byte in UInt8.min...UInt8.max {
            let encoded = Double(byte) / 255
            let expected = encoded <= 0.04045
                ? encoded / 12.92
                : pow((encoded + 0.055) / 1.055, 2.4)
            XCTAssertEqual(RoomMeshColor.sRGBToLinear(byte), expected, accuracy: 1e-15)
        }
    }

    func testSharpnessAnalysisIsBoundedForA1024PixelImage() {
        let width = 1_024
        let height = 768
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8(truncatingIfNeeded: x * 17 + y * 31)
                rgba[offset + 1] = UInt8(truncatingIfNeeded: x * 7 + y * 13)
                rgba[offset + 2] = UInt8(truncatingIfNeeded: x * 3 + y * 5)
            }
        }

        let started = ContinuousClock.now
        let sharpness = RoomMeshFrameAnalysis.luminanceSharpness(
            rgba: rgba,
            width: width,
            height: height
        )
        let elapsed = started.duration(to: .now)

        XCTAssertGreaterThan(sharpness, 0)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(600),
            "analysis must convert each source pixel once, not once per Laplacian neighbor"
        )
    }

    func testBufferedSharpnessMatchesTheDirectLinearLightFormula() {
        let width = 5
        let height = 5
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            rgba[index * 4] = UInt8(truncatingIfNeeded: index * 19)
            rgba[index * 4 + 1] = UInt8(truncatingIfNeeded: index * 37)
            rgba[index * 4 + 2] = UInt8(truncatingIfNeeded: index * 53)
        }
        func luminance(_ x: Int, _ y: Int) -> Double {
            let offset = (y * width + x) * 4
            return 0.2126 * RoomMeshColor.sRGBUnitToLinear(Double(rgba[offset]) / 255)
                + 0.7152 * RoomMeshColor.sRGBUnitToLinear(Double(rgba[offset + 1]) / 255)
                + 0.0722 * RoomMeshColor.sRGBUnitToLinear(Double(rgba[offset + 2]) / 255)
        }
        var count = 0
        var mean = 0.0
        var m2 = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let value = -8 * luminance(x, y)
                    + luminance(x - 1, y - 1) + luminance(x, y - 1) + luminance(x + 1, y - 1)
                    + luminance(x - 1, y) + luminance(x + 1, y)
                    + luminance(x - 1, y + 1) + luminance(x, y + 1) + luminance(x + 1, y + 1)
                count += 1
                let delta = value - mean
                mean += delta / Double(count)
                m2 += delta * (value - mean)
            }
        }
        let expected = m2 / Double(count - 1)

        XCTAssertEqual(
            RoomMeshFrameAnalysis.luminanceSharpness(rgba: rgba, width: width, height: height),
            expected,
            accuracy: 1e-15
        )
    }

    func testSRGBRoundTripAndLinearLightMidpoint() {
        XCTAssertEqual(RoomMeshColor.linearToSRGB(RoomMeshColor.sRGBToLinear(128)), 128)
        let image: [UInt8] = [
            0, 0, 0, 255,
            255, 255, 255, 255,
        ]
        let midpoint = RoomMeshColor.bilinearSample(
            rgba: image,
            width: 2,
            height: 1,
            x: 0.5,
            y: 0
        )
        XCTAssertEqual(RoomMeshColor.linearToSRGB(midpoint.x), 188, accuracy: 1)
        XCTAssertEqual(midpoint.x, 0.5, accuracy: 1e-12)
    }

    func testSampleScoreUsesEuclideanDistanceAndExactFactors() {
        let axial = RoomMeshFrameAnalysis.sampleScore(
            facingCosine: 1,
            euclideanDistance: 2,
            normalizedSharpness: 1,
            visibilityFactor: 1,
            isSaturated: false,
            isPhotometricallyConnected: true
        )
        let offAxis = RoomMeshFrameAnalysis.sampleScore(
            facingCosine: 1,
            euclideanDistance: 2.5,
            normalizedSharpness: 1,
            visibilityFactor: 0.9,
            isSaturated: true,
            isPhotometricallyConnected: false
        )
        XCTAssertEqual(axial, 0.25, accuracy: 1e-12)
        XCTAssertEqual(offAxis, (1 / 6.25) * 0.9 * 0.25 * 0.75, accuracy: 1e-12)
        XCTAssertGreaterThan(axial, offAxis)
    }

    func testSharpnessNormalizationUsesMedianAndClamp() {
        XCTAssertEqual(
            RoomMeshFrameAnalysis.normalizedSharpness([0, 1, 2, 100]),
            [0.5, 0.5, 1, 2]
        )
    }

    func testBestFiveRobustInliersRejectStrongerRawOutlier() throws {
        let red = SIMD3<Double>(RoomMeshColor.sRGBToLinear(240), 0, 0)
        let green = SIMD3<Double>(0, RoomMeshColor.sRGBToLinear(240), 0)
        let candidates = [
            RoomMeshColorCandidate(linearRGB: green, score: 100, frameIndex: 0),
            RoomMeshColorCandidate(linearRGB: red, score: 10, frameIndex: 1),
            RoomMeshColorCandidate(linearRGB: red * 0.98, score: 9, frameIndex: 2),
            RoomMeshColorCandidate(linearRGB: red * 1.01, score: 8, frameIndex: 3),
            RoomMeshColorCandidate(linearRGB: red * 0.99, score: 7, frameIndex: 4),
            RoomMeshColorCandidate(linearRGB: SIMD3<Double>(0, 0, 1), score: 6, frameIndex: 5),
        ]
        let selected = try XCTUnwrap(RoomMeshFrameAnalysis.bestInlier(from: candidates))
        XCTAssertNotEqual(selected.frameIndex, 0)
        XCTAssertGreaterThan(selected.linearRGB.x, selected.linearRGB.y)
    }

    func testPhotometricOverlapSolveUsesRobustMedianAndLeavesDisconnectedIdentity() {
        var samples = [[RoomMeshPhotometricSample]](repeating: [], count: 3)
        for sampleID in 0..<128 {
            let reference = SIMD3<Double>(0.20, 0.30, 0.40)
            samples[0].append(.init(sampleID: sampleID, linearRGB: reference))
            let biased = sampleID == 0
                ? SIMD3<Double>(0.95, 0.02, 0.90)
                : reference * 2
            samples[1].append(.init(sampleID: sampleID, linearRGB: biased))
        }

        let result = RoomMeshFrameAnalysis.solvePhotometricCalibration(
            samplesByFrame: samples,
            normalizedSharpness: [2, 1, 0.5]
        )

        XCTAssertEqual(result.anchorFrameIndex, 0)
        XCTAssertTrue(result.frames[0].isConnected)
        XCTAssertTrue(result.frames[1].isConnected)
        XCTAssertFalse(result.frames[2].isConnected)
        XCTAssertEqual(result.frames[0].logGain, .zero)
        XCTAssertEqual(result.frames[1].logGain.x, -log(2), accuracy: 0.015)
        XCTAssertEqual(result.frames[1].logGain.y, -log(2), accuracy: 0.015)
        XCTAssertEqual(result.frames[1].logGain.z, -log(2), accuracy: 0.015)
        XCTAssertEqual(result.frames[2].logGain, .zero)
    }

    func testPhotometricOverlapRequires128SamplesAndClampsGain() {
        var underconstrained = [[RoomMeshPhotometricSample]](repeating: [], count: 2)
        for sampleID in 0..<127 {
            underconstrained[0].append(.init(sampleID: sampleID, linearRGB: SIMD3(repeating: 0.1)))
            underconstrained[1].append(.init(sampleID: sampleID, linearRGB: SIMD3(repeating: 0.9)))
        }
        let disconnected = RoomMeshFrameAnalysis.solvePhotometricCalibration(
            samplesByFrame: underconstrained,
            normalizedSharpness: [1, 1]
        )
        XCTAssertFalse(disconnected.frames[1].isConnected)
        XCTAssertEqual(disconnected.frames[1].logGain, .zero)

        underconstrained[0].append(.init(sampleID: 127, linearRGB: SIMD3(repeating: 0.05)))
        underconstrained[1].append(.init(sampleID: 127, linearRGB: SIMD3(repeating: 0.95)))
        let clamped = RoomMeshFrameAnalysis.solvePhotometricCalibration(
            samplesByFrame: underconstrained,
            normalizedSharpness: [2, 1]
        )
        XCTAssertTrue(clamped.frames[1].isConnected)
        let luminance = (clamped.frames[1].logGain.x
            + clamped.frames[1].logGain.y
            + clamped.frames[1].logGain.z) / 3
        XCTAssertEqual(luminance, -log(2), accuracy: 1e-12)
        XCTAssertLessThanOrEqual(abs(clamped.frames[1].logGain.x - luminance), 0.25 + 1e-12)
    }

    func testPhotometricCalibrationSkipsUnrelatedLargeRoomFramePairs() {
        let frameCount = 192
        let samplesPerFrame = RoomMeshFrameAnalysis.maximumCalibrationSamplesPerFrame
        var samples = [[RoomMeshPhotometricSample]]()
        samples.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let firstID = frame * samplesPerFrame
            samples.append((0..<samplesPerFrame).map { offset in
                RoomMeshPhotometricSample(
                    sampleID: firstID + offset,
                    linearRGB: SIMD3<Double>(0.2, 0.3, 0.4)
                )
            })
        }

        let started = ContinuousClock.now
        let result = RoomMeshFrameAnalysis.solvePhotometricCalibration(
            samplesByFrame: samples,
            normalizedSharpness: [Double](repeating: 1, count: frameCount)
        )
        let elapsed = started.duration(to: .now)

        XCTAssertNil(result.anchorFrameIndex)
        XCTAssertEqual(result.frames.count, frameCount)
        XCTAssertTrue(result.frames.allSatisfy { !$0.isConnected && $0.logGain == .zero })
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "unrelated room views must not scan 4,096 sample IDs for every possible frame pair"
        )
    }
}
