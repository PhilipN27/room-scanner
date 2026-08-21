import Foundation
import XCTest
@testable import RoomScanStudio

@MainActor
final class MagicLinkCompletionTests: XCTestCase {
    func testRequestBuildsRFC7636S256ChallengeAndStableRecoveryMaterials() throws {
        let verifier = try hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let completionID = try hex("f0e0d0c0b0a090807060504030201000ffeeddccbbaa99887766554433221100")
        let request = try MagicLinkCompletionRequest(email: "pro@example.com", verifier: verifier)
        XCTAssertEqual(request.pkceChallenge, "Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0")
        XCTAssertEqual(try MagicLinkCompletionDerivation.access(verifier: verifier, completionID: completionID).hex, "f8d9f67de82c7022b4904d529feb67586284b6eb23ad06fcd776acb7b331977d")
        XCTAssertEqual(try MagicLinkCompletionDerivation.refresh(verifier: verifier, completionID: completionID).hex, "fc9a9ad46c435759bbe7c1aa28ba9b046d81347188e9253ff09c82c22a747410")
        XCTAssertEqual(try MagicLinkCompletionDerivation.receipt(verifier: verifier, completionID: completionID).hex, "6cb1cfadb5b5d7fb15523b1328aeff63b128e6ddda4c80694583a45ac557a951")
    }

    func testNormalizesHumanTransferCodeButRejectsAmbiguousOrWrongLengthInput() throws {
        XCTAssertEqual(try MagicLinkTransferCode(normalizing: " abcd-efgh ").canonical, "ABCDEFGH")
        XCTAssertThrowsError(try MagicLinkTransferCode(normalizing: "O1234567"))
        XCTAssertThrowsError(try MagicLinkTransferCode(normalizing: "ABCDEFG"))
    }

    func testCoordinatorRedeemsCrossDeviceCompletionAndRetriesLostResponseWithoutNewRequest() async throws {
        let client = RecordingMagicLinkClient()
        let store = MemoryMagicLinkTransientStore()
        let coordinator = MagicLinkCompletionCoordinator(client: client, store: store, randomBytes: { Data(repeating: 0xA5, count: $0) }, now: { Date(timeIntervalSince1970: 100) })
        try await coordinator.request(email: "pro@example.com")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].pkceChallenge.count, 43)
        XCTAssertEqual(client.requests[0].purpose, .signIn)
        XCTAssertNil(coordinator.pendingPlaintextVerifierForDiagnostics)
        client.redemptionFailuresBeforeSuccess = 1
        await XCTAssertMagicLinkThrows { try await coordinator.redeem(transferCode: "abcd-efgh") }
        XCTAssertEqual(client.redemptions.count, 1)
        XCTAssertTrue(store.hasPending)
        let completed = try await coordinator.redeem(transferCode: "ABCDEFGH")
        XCTAssertEqual(client.redemptions.count, 2)
        XCTAssertEqual(client.redemptions[1].purpose, .signIn)
        XCTAssertEqual(client.redemptions[1].completionIDBase64URL, Data(repeating: 7, count: 32).base64URLEncodedString())
        guard case let .session(access, refresh) = completed else { return XCTFail("Expected session material") }
        XCTAssertEqual(access.count, 32)
        XCTAssertEqual(refresh.count, 32)
        XCTAssertTrue(store.hasPending)
        try coordinator.acknowledgeCommittedCompletion()
        XCTAssertFalse(store.hasPending)
        XCTAssertNil(coordinator.pendingPlaintextVerifierForDiagnostics)
    }

    func testCoordinatorRejectsExpiredCompletionWithoutRedeeming() async throws {
        let client = RecordingMagicLinkClient()
        let store = MemoryMagicLinkTransientStore()
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let coordinator = MagicLinkCompletionCoordinator(client: client, store: store, randomBytes: { Data(repeating: 1, count: $0) }, now: { currentTime })
        client.nextResponse = MagicLinkCompletionResponse(completionID: Data(repeating: 9, count: 32), expiresAt: Date(timeIntervalSince1970: 1_001))
        try await coordinator.request(email: "pro@example.com")
        currentTime = Date(timeIntervalSince1970: 1_002)
        await XCTAssertMagicLinkThrows { try await coordinator.redeem(transferCode: "ABCDEFGH") }
        XCTAssertTrue(client.redemptions.isEmpty)
        XCTAssertFalse(store.hasPending)
    }

    func testCancellationAndBackgroundClearPlaintextButPreserveOnlySecurePendingState() async throws {
        let client = RecordingMagicLinkClient()
        let store = MemoryMagicLinkTransientStore()
        let coordinator = MagicLinkCompletionCoordinator(client: client, store: store, randomBytes: { Data(repeating: 2, count: $0) }, now: Date.init)
        try await coordinator.request(email: "pro@example.com")
        coordinator.handleLifecycle(.background)
        XCTAssertTrue(store.hasPending)
        XCTAssertNil(coordinator.pendingPlaintextVerifierForDiagnostics)
        coordinator.cancel()
        XCTAssertFalse(store.hasPending)
    }

    func testStorageFailureDoesNotLeaveRecoverablePlaintextInCoordinator() async {
        let client = RecordingMagicLinkClient()
        let coordinator = MagicLinkCompletionCoordinator(
            client: client,
            store: FailingMagicLinkTransientStore(),
            randomBytes: { Data(repeating: 3, count: $0) },
            now: Date.init
        )
        await XCTAssertMagicLinkThrows { try await coordinator.request(email: "pro@example.com") }
        XCTAssertNil(coordinator.pendingPlaintextVerifierForDiagnostics)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testRejectsSwappedServerPurposeAndKeepsPendingStateForSafeRetry() async throws {
        let client = RecordingMagicLinkClient()
        client.responsePurpose = .reauthenticate
        let store = MemoryMagicLinkTransientStore()
        let coordinator = MagicLinkCompletionCoordinator(client: client, store: store, randomBytes: { Data(repeating: 4, count: $0) }, now: Date.init)
        try await coordinator.request(email: "pro@example.com", purpose: .signIn)
        await XCTAssertMagicLinkThrows { try await coordinator.redeem(transferCode: "ABCDEFGH") }
        XCTAssertTrue(store.hasPending)
    }

    func testReauthenticationProducesSessionMaterialAndLinkingProducesReceiptOnly() async throws {
        let reauthClient = RecordingMagicLinkClient()
        let reauth = MagicLinkCompletionCoordinator(client: reauthClient, store: MemoryMagicLinkTransientStore(), randomBytes: { Data(repeating: 6, count: $0) }, now: Date.init)
        try await reauth.request(email: "pro@example.com", purpose: .reauthenticate)
        guard case .session = try await reauth.redeem(transferCode: "ABCDEFGH", expectedPurpose: .reauthenticate) else { return XCTFail("Expected reauthentication session") }

        let linkClient = RecordingMagicLinkClient()
        let link = MagicLinkCompletionCoordinator(client: linkClient, store: MemoryMagicLinkTransientStore(), randomBytes: { Data(repeating: 7, count: $0) }, now: Date.init)
        try await link.request(email: "pro@example.com", purpose: .linkIdentity)
        guard case let .receipt(receipt) = try await link.redeem(transferCode: "ABCDEFGH", expectedPurpose: .linkIdentity) else { return XCTFail("Expected linking receipt") }
        XCTAssertEqual(receipt.count, 32)
    }
}

private final class RecordingMagicLinkClient: MagicLinkCompletionClient {
    var requests: [MagicLinkCompletionRequest] = []
    var redemptions: [MagicLinkRedemptionRequest] = []
    var redemptionFailuresBeforeSuccess = 0
    var responsePurpose: MagicLinkCompletionPurpose?
    var nextResponse = MagicLinkCompletionResponse(completionID: Data(repeating: 7, count: 32), expiresAt: .distantFuture)
    func requestCompletion(_ request: MagicLinkCompletionRequest) async throws -> MagicLinkCompletionResponse { requests.append(request); return nextResponse }
    func redeemCompletion(_ request: MagicLinkRedemptionRequest) async throws -> MagicLinkRedemptionResponse { redemptions.append(request); if redemptionFailuresBeforeSuccess > 0 { redemptionFailuresBeforeSuccess -= 1; throw URLError(.networkConnectionLost) }; return MagicLinkRedemptionResponse(purpose: responsePurpose ?? request.purpose, expiresAt: .distantFuture, consumed: true) }
}

private final class MemoryMagicLinkTransientStore: MagicLinkTransientStateStore {
    var pending: MagicLinkPendingState?
    var hasPending: Bool { pending != nil }
    func save(_ state: MagicLinkPendingState) throws { pending = state }
    func load() throws -> MagicLinkPendingState? { pending }
    func clear() throws { pending = nil }
}

private final class FailingMagicLinkTransientStore: MagicLinkTransientStateStore {
    func save(_ state: MagicLinkPendingState) throws { throw MagicLinkCompletionError.storageFailure }
    func load() throws -> MagicLinkPendingState? { throw MagicLinkCompletionError.storageFailure }
    func clear() throws {}
}

private func hex(_ source: String) throws -> Data { var data = Data(); var cursor = source.startIndex; while cursor < source.endIndex { let end = source.index(cursor, offsetBy: 2); guard let byte = UInt8(source[cursor..<end], radix: 16) else { throw CocoaError(.fileReadCorruptFile) }; data.append(byte); cursor = end }; return data }
private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
private extension Data { func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
private func XCTAssertMagicLinkThrows(_ expression: @escaping () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async { do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {} }
