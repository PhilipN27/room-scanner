import Foundation
import Vision

enum RoomAISensitiveContentAdvisoryKind: String, CaseIterable, Sendable, Equatable {
    case possiblePersonOrFace
    case possibleDocumentOrScreen
    case possibleAddressOrLocationText
    case reviewFamilyPhotographs
    case reviewReflectiveSurfaces
    case reviewScreenOrDocumentExposure
    case reviewPreciseLocationExposure
}

enum RoomAISensitiveContentAdvisoryBasis: String, Sendable, Equatable {
    case automaticSignal
    case userReviewRequired
}

struct RoomAISensitiveContentAdvisory: Sendable, Equatable, Identifiable {
    var id: RoomAISensitiveContentAdvisoryKind { kind }
    let kind: RoomAISensitiveContentAdvisoryKind
    let basis: RoomAISensitiveContentAdvisoryBasis
    let message: String
}

enum RoomAISensitiveContentAnalysisError: Error, Equatable {
    case invalidImage
    case analysisFailed
}

struct RoomAISensitiveContentAnalysisSignals: Sendable, Equatable {
    let faceCount: Int
    let humanCount: Int
    let recognizedText: [String]
}

protocol RoomAISensitiveContentAnalysisOperation: AnyObject, Sendable {
    func perform() throws -> RoomAISensitiveContentAnalysisSignals
    func cancel()
}

final class RoomAISensitiveContentAnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOccupied = false

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOccupied else { return false }
        isOccupied = true
        return true
    }

    func release() {
        lock.lock()
        isOccupied = false
        lock.unlock()
    }
}

/// Vision supplies bounded advisory signals only. The fixed manual prompts
/// preserve the truth that no local detector can establish that an image is
/// free of photographs, documents, addresses, screens, or reflections.
enum RoomAISensitiveContentAnalyzer {
    static let disclaimer = "Advisory detection may miss sensitive content and does not redact anything. Review every selected image before sharing."
    private static let optionalAnalysisTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let productionGate = RoomAISensitiveContentAnalysisGate()

    static func analyze(
        _ image: RoomAISanitizedImage
    ) async throws -> [RoomAISensitiveContentAdvisory] {
        try await analyze(
            image,
            timeoutNanoseconds: optionalAnalysisTimeoutNanoseconds,
            gate: productionGate,
            operationFactory: { data in
                RoomAIVisionSensitiveContentAnalysisOperation(data: data)
            }
        )
    }

    static func analyze(
        _ image: RoomAISanitizedImage,
        timeoutNanoseconds: UInt64,
        gate: RoomAISensitiveContentAnalysisGate,
        operationFactory: @escaping @Sendable (Data) -> any RoomAISensitiveContentAnalysisOperation
    ) async throws -> [RoomAISensitiveContentAdvisory] {
        let data = image.data
        guard !data.isEmpty else {
            throw RoomAISensitiveContentAnalysisError.invalidImage
        }
        try Task.checkCancellation()
        guard gate.acquire() else {
            try Task.checkCancellation()
            return unavailableAdvisories()
        }

        let attempt = RoomAISensitiveContentAnalysisAttempt(
            operation: operationFactory(data),
            gate: gate
        )
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.start(
                    timeoutNanoseconds: timeoutNanoseconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            attempt.cancelForCaller()
        }

        switch outcome {
        case let .success(signals):
            return advisories(
                faceCount: signals.faceCount,
                humanCount: signals.humanCount,
                recognizedText: signals.recognizedText
            )
        case .analysisFailed, .timedOut:
            return unavailableAdvisories()
        case .cancelled:
            throw CancellationError()
        }
    }

    static func advisories(
        faceCount: Int,
        humanCount: Int,
        recognizedText: [String]
    ) -> [RoomAISensitiveContentAdvisory] {
        let normalizedText = recognizedText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var values: [RoomAISensitiveContentAdvisory] = []
        if faceCount > 0 || humanCount > 0 {
            values.append(.init(
                kind: .possiblePersonOrFace,
                basis: .automaticSignal,
                message: "A person or face may be visible."
            ))
        }
        if normalizedText.contains(where: { $0.count >= 4 }) {
            values.append(.init(
                kind: .possibleDocumentOrScreen,
                basis: .automaticSignal,
                message: "Recognized text may come from a document, photograph, label, or screen."
            ))
        }
        if normalizedText.contains(where: likelyContainsAddressOrLocation) {
            values.append(.init(
                kind: .possibleAddressOrLocationText,
                basis: .automaticSignal,
                message: "Recognized text may disclose an address or location."
            ))
        }
        values.append(contentsOf: [
            .init(
                kind: .reviewFamilyPhotographs,
                basis: .userReviewRequired,
                message: "Check for family or personal photographs that automation may miss."
            ),
            .init(
                kind: .reviewReflectiveSurfaces,
                basis: .userReviewRequired,
                message: "Check mirrors, windows, and glossy surfaces for reflections."
            ),
            .init(
                kind: .reviewScreenOrDocumentExposure,
                basis: .userReviewRequired,
                message: "Check screens, mail, labels, calendars, and documents for private details."
            ),
            .init(
                kind: .reviewPreciseLocationExposure,
                basis: .userReviewRequired,
                message: "Check visible signs and text for precise-location disclosure. Package metadata excludes precise GPS."
            ),
        ])
        return values
    }

    private static func unavailableAdvisories() -> [RoomAISensitiveContentAdvisory] {
        advisories(faceCount: 0, humanCount: 0, recognizedText: []).map { advisory in
            guard advisory.kind == .reviewScreenOrDocumentExposure else {
                return advisory
            }
            return .init(
                kind: advisory.kind,
                basis: advisory.basis,
                message: "Automatic sensitive-content analysis was unavailable. \(disclaimer) \(advisory.message)"
            )
        }
    }

    private static func likelyContainsAddressOrLocation(_ value: String) -> Bool {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let streetWords = [
            " street", " st ", " road", " rd ", " avenue", " ave ",
            " lane", " drive", " boulevard", " postcode", " zip code",
        ]
        if folded.contains(where: \.isNumber), streetWords.contains(where: folded.contains) {
            return true
        }
        let compact = folded.replacingOccurrences(of: " ", with: "")
        let ukPostcodePattern = #"[a-z]{1,2}[0-9][a-z0-9]?[0-9][a-z]{2}"#
        return compact.range(of: ukPostcodePattern, options: .regularExpression) != nil
    }
}

private final class RoomAIVisionSensitiveContentAnalysisOperation:
    RoomAISensitiveContentAnalysisOperation,
    @unchecked Sendable
{
    private let faces = VNDetectFaceRectanglesRequest()
    private let humans = VNDetectHumanRectanglesRequest()
    private let text = VNRecognizeTextRequest()
    private let handler: VNImageRequestHandler

    init(data: Data) {
        humans.upperBodyOnly = false
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        handler = VNImageRequestHandler(data: data, options: [:])
    }

    func perform() throws -> RoomAISensitiveContentAnalysisSignals {
        do {
            try handler.perform([faces, humans, text])
        } catch {
            throw RoomAISensitiveContentAnalysisError.analysisFailed
        }
        return .init(
            faceCount: faces.results?.count ?? 0,
            humanCount: humans.results?.count ?? 0,
            recognizedText: (text.results ?? []).compactMap {
                $0.topCandidates(1).first?.string
            }
        )
    }

    func cancel() {
        faces.cancel()
        humans.cancel()
        text.cancel()
    }
}

private enum RoomAISensitiveContentAnalysisOutcome: Sendable {
    case success(RoomAISensitiveContentAnalysisSignals)
    case analysisFailed
    case timedOut
    case cancelled
}

private final class RoomAISensitiveContentAnalysisAttempt: @unchecked Sendable {
    private let operation: any RoomAISensitiveContentAnalysisOperation
    private let gate: RoomAISensitiveContentAnalysisGate
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RoomAISensitiveContentAnalysisOutcome, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var resolvedOutcome: RoomAISensitiveContentAnalysisOutcome?

    init(
        operation: any RoomAISensitiveContentAnalysisOperation,
        gate: RoomAISensitiveContentAnalysisGate
    ) {
        self.operation = operation
        self.gate = gate
    }

    func start(
        timeoutNanoseconds: UInt64,
        continuation: CheckedContinuation<RoomAISensitiveContentAnalysisOutcome, Never>
    ) {
        lock.lock()
        if let resolvedOutcome {
            lock.unlock()
            gate.release()
            continuation.resume(returning: resolvedOutcome)
            return
        }
        self.continuation = continuation
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            let outcome: RoomAISensitiveContentAnalysisOutcome
            do {
                outcome = .success(try operation.perform())
            } catch {
                outcome = .analysisFailed
            }
            gate.release()
            resolve(outcome)
        }

        let deadlineTask = Task.detached(priority: .utility) { [self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            if resolve(.timedOut) {
                requestCancellation()
            }
        }
        install(deadlineTask: deadlineTask)
    }

    func cancelForCaller() {
        if resolve(.cancelled) {
            requestCancellation()
        }
    }

    private func install(deadlineTask: Task<Void, Never>) {
        lock.lock()
        if resolvedOutcome == nil {
            self.deadlineTask = deadlineTask
            lock.unlock()
        } else {
            lock.unlock()
            deadlineTask.cancel()
        }
    }

    @discardableResult
    private func resolve(_ outcome: RoomAISensitiveContentAnalysisOutcome) -> Bool {
        let continuation: CheckedContinuation<RoomAISensitiveContentAnalysisOutcome, Never>?
        let deadlineTask: Task<Void, Never>?
        lock.lock()
        guard resolvedOutcome == nil else {
            lock.unlock()
            return false
        }
        resolvedOutcome = outcome
        continuation = self.continuation
        deadlineTask = self.deadlineTask
        self.continuation = nil
        self.deadlineTask = nil
        lock.unlock()

        deadlineTask?.cancel()
        continuation?.resume(returning: outcome)
        return true
    }

    private func requestCancellation() {
        let operation = operation
        Task.detached(priority: .utility) {
            operation.cancel()
        }
    }
}
