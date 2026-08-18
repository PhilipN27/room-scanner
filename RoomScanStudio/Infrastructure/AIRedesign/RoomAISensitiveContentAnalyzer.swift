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

/// Vision supplies bounded advisory signals only. The fixed manual prompts
/// preserve the truth that no local detector can establish that an image is
/// free of photographs, documents, addresses, screens, or reflections.
enum RoomAISensitiveContentAnalyzer {
    static let disclaimer = "Advisory detection may miss sensitive content and does not redact anything. Review every selected image before sharing."

    static func analyze(
        _ image: RoomAISanitizedImage
    ) async throws -> [RoomAISensitiveContentAdvisory] {
        let data = image.data
        return try await Task.detached(priority: .utility) {
            guard !data.isEmpty else {
                throw RoomAISensitiveContentAnalysisError.invalidImage
            }
            let faces = VNDetectFaceRectanglesRequest()
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .fast
            text.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(data: data, options: [:])
            do {
                try handler.perform([faces, humans, text])
            } catch {
                throw RoomAISensitiveContentAnalysisError.analysisFailed
            }
            let recognizedText = (text.results ?? []).compactMap {
                $0.topCandidates(1).first?.string
            }
            return advisories(
                faceCount: faces.results?.count ?? 0,
                humanCount: humans.results?.count ?? 0,
                recognizedText: recognizedText
            )
        }.value
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
