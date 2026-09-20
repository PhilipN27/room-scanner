import XCTest
import UIKit
@testable import RoomScanStudio

final class RoomAISensitiveContentAnalyzerTests: XCTestCase {
    func testColdRealVisionReturnsAutomaticSignalOrTruthfulFallbackWithinOptionalBudget() async throws {
        let image = await MainActor.run {
            let size = CGSize(width: 640, height: 240)
            let rendered = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ("42 MAIN STREET" as NSString).draw(
                    at: CGPoint(x: 42, y: 76),
                    withAttributes: [
                        .font: UIFont.boldSystemFont(ofSize: 62),
                        .foregroundColor: UIColor.black,
                    ]
                )
            }
            return RoomAISanitizedImage(
                data: rendered.jpegData(compressionQuality: 0.9)!,
                mediaType: "image/jpeg",
                pixelWidth: Int(size.width),
                pixelHeight: Int(size.height)
            )
        }

        let advisories = try await RoomAISensitiveContentAnalyzer.analyze(image)

        let hasAutomaticSignal = advisories.contains { $0.basis == .automaticSignal }
        if !hasAutomaticSignal {
            XCTAssertEqual(advisories.map(\.kind), [
                .reviewFamilyPhotographs,
                .reviewReflectiveSurfaces,
                .reviewScreenOrDocumentExposure,
                .reviewPreciseLocationExposure,
            ])
            XCTAssertTrue(advisories.contains {
                $0.message.contains(RoomAISensitiveContentAnalyzer.disclaimer)
            })
        }
    }

    func testCallerCancellationReturnsBeforeBlockingAnalysisCancellationFinishes() async throws {
        let operation = BlockingCancellationSensitiveContentAnalysisOperation()
        defer {
            operation.allowCancellationToFinish.signal()
            operation.allowAnalysisToFinish.signal()
        }
        let analysisTask = Task {
            try await RoomAISensitiveContentAnalyzer.analyze(
                testImage(),
                timeoutNanoseconds: 5_000_000_000,
                gate: RoomAISensitiveContentAnalysisGate(),
                operationFactory: { _ in operation }
            )
        }
        XCTAssertEqual(operation.started.wait(timeout: .now() + 1), .success)

        let returned = expectation(description: "cancelled analysis returned")
        let cancellationObserved = LockedInvocationCount()
        Task {
            do {
                _ = try await analysisTask.value
            } catch is CancellationError {
                cancellationObserved.increment()
            } catch {
                XCTFail("Expected CancellationError, got \(error).")
            }
            returned.fulfill()
        }
        Task.detached {
            analysisTask.cancel()
        }

        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(cancellationObserved.value, 1)
        XCTAssertEqual(
            operation.cancellationStarted.wait(timeout: .now() + 1),
            .success
        )
    }

    func testTimedOutOptionalAnalysisRequestsCancellationBoundsLateWorkAndKeepsManualReview() async throws {
        let gate = RoomAISensitiveContentAnalysisGate()
        let slow = ControlledSensitiveContentAnalysisOperation(
            signals: .init(
                faceCount: 1,
                humanCount: 0,
                recognizedText: ["42 Example Street"]
            ),
            waitsForRelease: true
        )
        defer { slow.allowCompletion.signal() }

        let fallback = try await RoomAISensitiveContentAnalyzer.analyze(
            testImage(),
            timeoutNanoseconds: 20_000_000,
            gate: gate,
            operationFactory: { _ in slow }
        )

        XCTAssertEqual(slow.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(slow.cancellationRequested.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(fallback.map(\.kind), [
            .reviewFamilyPhotographs,
            .reviewReflectiveSurfaces,
            .reviewScreenOrDocumentExposure,
            .reviewPreciseLocationExposure,
        ])
        XCTAssertTrue(fallback.allSatisfy { $0.basis == .userReviewRequired })
        XCTAssertTrue(fallback.contains {
            $0.message.contains(RoomAISensitiveContentAnalyzer.disclaimer)
        })

        let skippedFactory = LockedInvocationCount()
        let whileLateWorkerIsStillRunning = try await RoomAISensitiveContentAnalyzer.analyze(
            testImage(),
            timeoutNanoseconds: 20_000_000,
            gate: gate,
            operationFactory: { _ in
                skippedFactory.increment()
                return ImmediateSensitiveContentAnalysisOperation(
                    signals: .init(faceCount: 1, humanCount: 0, recognizedText: [])
                )
            }
        )
        XCTAssertEqual(skippedFactory.value, 0)
        XCTAssertEqual(whileLateWorkerIsStillRunning.map(\.kind), fallback.map(\.kind))

        slow.allowCompletion.signal()
        XCTAssertEqual(slow.finished.wait(timeout: .now() + 1), .success)

        let successfulFactory = LockedInvocationCount()
        var successful: [RoomAISensitiveContentAdvisory]?
        for _ in 0..<100 where successful == nil {
            let result = try await RoomAISensitiveContentAnalyzer.analyze(
                testImage(),
                timeoutNanoseconds: 200_000_000,
                gate: gate,
                operationFactory: { _ in
                    successfulFactory.increment()
                    return ImmediateSensitiveContentAnalysisOperation(
                        signals: .init(faceCount: 1, humanCount: 0, recognizedText: [])
                    )
                }
            )
            if successfulFactory.value > 0 {
                successful = result
            } else {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        XCTAssertEqual(successfulFactory.value, 1)
        XCTAssertTrue(successful?.contains { $0.kind == .possiblePersonOrFace } == true)
        XCTAssertFalse(fallback.contains { $0.kind == .possiblePersonOrFace })
    }

    func testInjectedAnalysisCompletingBeforeDeadlinePreservesAutomaticAndManualSignals() async throws {
        let advisories = try await RoomAISensitiveContentAnalyzer.analyze(
            testImage(),
            timeoutNanoseconds: 200_000_000,
            gate: RoomAISensitiveContentAnalysisGate(),
            operationFactory: { _ in
                ImmediateSensitiveContentAnalysisOperation(
                    signals: .init(
                        faceCount: 0,
                        humanCount: 1,
                        recognizedText: ["Quarterly project notes"]
                    )
                )
            }
        )

        XCTAssertTrue(advisories.contains { $0.kind == .possiblePersonOrFace })
        XCTAssertTrue(advisories.contains { $0.kind == .possibleDocumentOrScreen })
        XCTAssertTrue(advisories.contains { $0.kind == .reviewFamilyPhotographs })
        XCTAssertTrue(advisories.contains { $0.kind == .reviewPreciseLocationExposure })
    }

    func testFailedOptionalAnalysisKeepsEveryManualAdvisoryAndTruthfulUnavailableNotice() async throws {
        let advisories = try await RoomAISensitiveContentAnalyzer.analyze(
            testImage(),
            timeoutNanoseconds: 200_000_000,
            gate: RoomAISensitiveContentAnalysisGate(),
            operationFactory: { _ in FailingSensitiveContentAnalysisOperation() }
        )

        XCTAssertEqual(advisories.map(\.kind), [
            .reviewFamilyPhotographs,
            .reviewReflectiveSurfaces,
            .reviewScreenOrDocumentExposure,
            .reviewPreciseLocationExposure,
        ])
        XCTAssertTrue(advisories.allSatisfy { $0.basis == .userReviewRequired })
        XCTAssertTrue(advisories.contains {
            $0.message.contains("Automatic sensitive-content analysis was unavailable")
                && $0.message.contains(RoomAISensitiveContentAnalyzer.disclaimer)
        })
    }

    func testInvalidImageStillThrowsBeforeStartingInjectedAnalysis() async {
        let factory = LockedInvocationCount()
        let empty = RoomAISanitizedImage(
            data: Data(),
            mediaType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        do {
            _ = try await RoomAISensitiveContentAnalyzer.analyze(
                empty,
                timeoutNanoseconds: 20_000_000,
                gate: RoomAISensitiveContentAnalysisGate(),
                operationFactory: { _ in
                    factory.increment()
                    return ImmediateSensitiveContentAnalysisOperation(
                        signals: .init(faceCount: 0, humanCount: 0, recognizedText: [])
                    )
                }
            )
            XCTFail("Expected empty image data to remain invalid.")
        } catch {
            XCTAssertEqual(error as? RoomAISensitiveContentAnalysisError, .invalidImage)
        }
        XCTAssertEqual(factory.value, 0)
    }

    func testAutomaticEvidenceAndManualReviewPromptsUseCanonicalNonDuplicateOrder() {
        let advisories = RoomAISensitiveContentAnalyzer.advisories(
            faceCount: 1,
            humanCount: 1,
            recognizedText: [
                "42 Example Street London SW1A 1AA",
                "Household calendar",
            ]
        )

        XCTAssertEqual(advisories.map(\.kind), [
            .possiblePersonOrFace,
            .possibleDocumentOrScreen,
            .possibleAddressOrLocationText,
            .reviewFamilyPhotographs,
            .reviewReflectiveSurfaces,
            .reviewScreenOrDocumentExposure,
            .reviewPreciseLocationExposure,
        ])
        XCTAssertEqual(Set(advisories.map(\.kind)).count, advisories.count)
        XCTAssertEqual(advisories.first?.basis, .automaticSignal)
        XCTAssertEqual(advisories.last?.basis, .userReviewRequired)
    }

    func testAbsenceOfMachineSignalNeverClaimsSensitiveContentIsAbsent() {
        let advisories = RoomAISensitiveContentAnalyzer.advisories(
            faceCount: 0,
            humanCount: 0,
            recognizedText: []
        )

        XCTAssertEqual(advisories.map(\.kind), [
            .reviewFamilyPhotographs,
            .reviewReflectiveSurfaces,
            .reviewScreenOrDocumentExposure,
            .reviewPreciseLocationExposure,
        ])
        XCTAssertTrue(RoomAISensitiveContentAnalyzer.disclaimer.contains("may miss"))
        XCTAssertTrue(RoomAISensitiveContentAnalyzer.disclaimer.contains("does not redact"))
    }

    func testTextWithoutAddressGetsDocumentSignalButNotLocationSignal() {
        let advisories = RoomAISensitiveContentAnalyzer.advisories(
            faceCount: 0,
            humanCount: 0,
            recognizedText: ["Quarterly project notes"]
        )

        XCTAssertTrue(advisories.contains { $0.kind == .possibleDocumentOrScreen })
        XCTAssertFalse(advisories.contains { $0.kind == .possibleAddressOrLocationText })
    }

    private func testImage() -> RoomAISanitizedImage {
        RoomAISanitizedImage(
            data: Data([0x01]),
            mediaType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
    }
}

private final class ControlledSensitiveContentAnalysisOperation:
    RoomAISensitiveContentAnalysisOperation,
    @unchecked Sendable
{
    let started = DispatchSemaphore(value: 0)
    let cancellationRequested = DispatchSemaphore(value: 0)
    let allowCompletion = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    private let signals: RoomAISensitiveContentAnalysisSignals
    private let waitsForRelease: Bool

    init(signals: RoomAISensitiveContentAnalysisSignals, waitsForRelease: Bool) {
        self.signals = signals
        self.waitsForRelease = waitsForRelease
    }

    func perform() throws -> RoomAISensitiveContentAnalysisSignals {
        started.signal()
        if waitsForRelease {
            allowCompletion.wait()
        }
        finished.signal()
        return signals
    }

    func cancel() {
        cancellationRequested.signal()
    }
}

private final class ImmediateSensitiveContentAnalysisOperation:
    RoomAISensitiveContentAnalysisOperation,
    @unchecked Sendable
{
    private let signals: RoomAISensitiveContentAnalysisSignals

    init(signals: RoomAISensitiveContentAnalysisSignals) {
        self.signals = signals
    }

    func perform() throws -> RoomAISensitiveContentAnalysisSignals { signals }
    func cancel() {}
}

private final class FailingSensitiveContentAnalysisOperation:
    RoomAISensitiveContentAnalysisOperation,
    Sendable
{
    func perform() throws -> RoomAISensitiveContentAnalysisSignals {
        throw RoomAISensitiveContentAnalysisError.analysisFailed
    }
    func cancel() {}
}

private final class BlockingCancellationSensitiveContentAnalysisOperation:
    RoomAISensitiveContentAnalysisOperation,
    @unchecked Sendable
{
    let started = DispatchSemaphore(value: 0)
    let cancellationStarted = DispatchSemaphore(value: 0)
    let allowCancellationToFinish = DispatchSemaphore(value: 0)
    let allowAnalysisToFinish = DispatchSemaphore(value: 0)

    func perform() throws -> RoomAISensitiveContentAnalysisSignals {
        started.signal()
        allowAnalysisToFinish.wait()
        return .init(faceCount: 0, humanCount: 0, recognizedText: [])
    }

    func cancel() {
        cancellationStarted.signal()
        allowCancellationToFinish.wait()
    }
}

private final class LockedInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
