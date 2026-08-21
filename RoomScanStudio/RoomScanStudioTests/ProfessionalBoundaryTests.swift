import Combine
import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import RoomScanStudio

@MainActor
final class ProfessionalBoundaryTests: XCTestCase {
    func testDefaultProfessionalFactoryIsOffAndConstructsNothingBeforeOrAfterEntry() async {
        let factory = ProfessionalEnvironmentFactory.defaultOff()

        XCTAssertEqual(factory.state, .notEntered)
        XCTAssertFalse(factory.hasConstructedEnvironment)

        await factory.enterProfessionalWorkspace()

        XCTAssertEqual(
            factory.state,
            .unavailable("Professional workspaces are not configured in this build.")
        )
        XCTAssertFalse(factory.hasConstructedEnvironment)
    }

    func testConfiguredFactoryConstructsEveryDependencyAndFetchesKillSwitchOnlyAfterExplicitEntry() async throws {
        let environmentConstruction = InvocationRecorder()
        let availabilityConstruction = InvocationRecorder()
        let sessionConstruction = InvocationRecorder()
        let contextFactoryConstruction = InvocationRecorder()
        var constructedAvailability: RecordingProfessionalAvailabilityClient?
        var constructedSession: RecordingProfessionalSessionClient?
        var constructedContextFactory: RecordingDeviceAuthenticationContextFactory?
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                environmentConstruction.record()
                availabilityConstruction.record()
                let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
                constructedAvailability = availability
                sessionConstruction.record()
                let session = RecordingProfessionalSessionClient()
                constructedSession = session
                contextFactoryConstruction.record()
                let contextFactory = RecordingDeviceAuthenticationContextFactory(contexts: [])
                constructedContextFactory = contextFactory
                return ProfessionalEnvironment(
                    availabilityClient: availability,
                    sessionClient: session,
                    deviceAuthentication: DeviceAuthenticationCoordinator(
                        contextFactory: contextFactory
                    )
                )
            }
        )

        XCTAssertEqual(environmentConstruction.count, 0)
        XCTAssertEqual(availabilityConstruction.count, 0)
        XCTAssertEqual(sessionConstruction.count, 0)
        XCTAssertEqual(contextFactoryConstruction.count, 0)
        XCTAssertNil(constructedAvailability)
        XCTAssertNil(constructedSession)
        XCTAssertNil(constructedContextFactory)
        XCTAssertFalse(factory.hasConstructedEnvironment)

        await factory.enterProfessionalWorkspace()

        XCTAssertEqual(environmentConstruction.count, 1)
        XCTAssertEqual(availabilityConstruction.count, 1)
        XCTAssertEqual(sessionConstruction.count, 1)
        XCTAssertEqual(contextFactoryConstruction.count, 1)
        XCTAssertEqual(try XCTUnwrap(constructedAvailability).fetchCount, 1)
        XCTAssertEqual(try XCTUnwrap(constructedSession).beginSignInCount, 0)
        XCTAssertEqual(try XCTUnwrap(constructedContextFactory).makeCount, 0)
        XCTAssertEqual(factory.state, .available)
        XCTAssertTrue(factory.hasConstructedEnvironment)
    }

    func testDisabledServerStatePresentsUnavailableAndNeverStartsSignIn() async {
        let availability = RecordingProfessionalAvailabilityClient(
            result: .disabled(message: "Professional access is temporarily unavailable.")
        )
        let session = RecordingProfessionalSessionClient()
        let factory = makeProfessionalFactory(
            availability: availability,
            session: session,
            contexts: []
        )

        await factory.enterProfessionalWorkspace()
        let signIn = await factory.beginSignIn()

        XCTAssertEqual(
            factory.state,
            .unavailable("Professional access is temporarily unavailable.")
        )
        XCTAssertEqual(
            signIn,
            .unavailable("Professional access is temporarily unavailable.")
        )
        XCTAssertEqual(session.beginSignInCount, 0)
    }

    func testAvailableProfessionalSignInStillRequiresSuccessfulLocalUnlock() async {
        let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
        let session = RecordingProfessionalSessionClient()
        let noPasscode = RecordingDeviceAuthenticationContext(
            preflight: .failure(.noPasscode),
            evaluation: .success,
            domainState: nil
        )
        let factory = makeProfessionalFactory(
            availability: availability,
            session: session,
            contexts: [noPasscode]
        )

        await factory.enterProfessionalWorkspace()
        let authentication = await factory.requestLocalUnlock()
        let signIn = await factory.beginSignIn()

        XCTAssertEqual(authentication, .noPasscode)
        XCTAssertEqual(
            signIn,
            .unavailable(
                "Unlock the professional workspace with Face ID or device passcode before signing in."
            )
        )
        XCTAssertEqual(session.beginSignInCount, 0)
    }

    func testGuestAppEnvironmentLaunchDoesNotConstructOrQueryProfessionalDependencies() {
        let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
        let session = RecordingProfessionalSessionClient()
        let construction = InvocationRecorder()
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                construction.record()
                return ProfessionalEnvironment(
                    availabilityClient: availability,
                    sessionClient: session,
                    deviceAuthentication: DeviceAuthenticationCoordinator(
                        contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [])
                    )
                )
            }
        )
        let arguments = ["--ui-testing", "--reset-local-store", "--use-simulated-capture"]

        _ = AppEnvironment(
            arguments: arguments,
            professionalEnvironmentFactory: factory
        )

        XCTAssertEqual(construction.count, 0)
        XCTAssertEqual(availability.fetchCount, 0)
        XCTAssertEqual(session.beginSignInCount, 0)
        XCTAssertFalse(factory.hasConstructedEnvironment)
    }

#if DEBUG
    func testPhysicalProfessionalEvidenceGateRequiresDebugPhysicalDeviceAndBothExplicitFlags() {
        for isDebugBuild in [false, true] {
            for isPhysicalDevice in [false, true] {
                for hasUITestingFlag in [false, true] {
                    for hasEvidenceFlag in [false, true] {
                        var arguments = ["RoomScanStudio"]
                        if hasUITestingFlag { arguments.append("--ui-testing") }
                        if hasEvidenceFlag {
                            arguments.append("--physical-professional-evidence")
                        }
                        XCTAssertEqual(
                            PhysicalProfessionalEvidenceHarness.isEnabled(
                                arguments: arguments,
                                isDebugBuild: isDebugBuild,
                                isPhysicalDevice: isPhysicalDevice
                            ),
                            isDebugBuild
                                && isPhysicalDevice
                                && hasUITestingFlag
                                && hasEvidenceFlag,
                            "Unexpected gate result for \(arguments), debug=\(isDebugBuild), physical=\(isPhysicalDevice)"
                        )
                    }
                }
            }
        }
    }

    func testPhysicalProfessionalEvidenceSimulatorAppCompositionStaysDefaultOffWithBothFlags() async {
#if targetEnvironment(simulator)
        let environment = AppEnvironment(arguments: [
            "RoomScanStudio",
            "--ui-testing",
            "--physical-professional-evidence",
            "--reset-local-store",
            "--use-mock-fixture",
            "--use-simulated-capture",
        ])

        await environment.professionalEnvironmentFactory.enterProfessionalWorkspace()

        XCTAssertEqual(
            environment.professionalEnvironmentFactory.state,
            .unavailable(ProfessionalEnvironmentFactory.locallyUnavailableMessage)
        )
        XCTAssertFalse(
            environment.professionalEnvironmentFactory.hasConstructedEnvironment
        )
#endif
    }

    func testPhysicalProfessionalEvidenceEnabledFactoryIsLazyAndExposesOnlyBooleanDiagnostics() async throws {
        let fixture = makePhysicalProfessionalEvidenceFixture(contexts: [])

        XCTAssertEqual(fixture.authenticationFactoryConstruction.count, 0)
        XCTAssertEqual(fixture.storeConstruction.count, 0)
        XCTAssertEqual(fixture.random.requestedCounts, [])
        XCTAssertFalse(fixture.factory.hasConstructedEnvironment)

        await fixture.factory.enterProfessionalWorkspace()

        XCTAssertEqual(fixture.factory.state, .available)
        XCTAssertTrue(fixture.factory.hasConstructedEnvironment)
        XCTAssertEqual(fixture.authenticationFactoryConstruction.count, 1)
        XCTAssertEqual(fixture.storeConstruction.count, 1)
        XCTAssertEqual(fixture.authenticationContexts.makeCount, 0)
        XCTAssertEqual(fixture.random.requestedCounts, [])
        XCTAssertEqual(fixture.factory.physicalEvidenceExternalDependencyCount, 0)
        let snapshot = try XCTUnwrap(fixture.factory.physicalEvidenceSnapshot)
        XCTAssertTrue(snapshot.isProtectedUIObscured)
        XCTAssertFalse(snapshot.hasValidLocalProof)
        XCTAssertFalse(snapshot.hasSyntheticSessionMaterial)
        XCTAssertFalse(snapshot.hasPendingCompletion)
        XCTAssertNil(snapshot.lastPendingItemInspectionFound)
        for child in Mirror(reflecting: snapshot).children {
            XCTAssertFalse(child.value is Data)
            XCTAssertFalse(child.value is String)
        }
    }

    func testPhysicalProfessionalEvidenceSyntheticSessionSensitiveActionAndBackgroundClearing() async throws {
        let fixture = makePhysicalProfessionalEvidenceFixture(contexts: [
            RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .success,
                domainState: Data([0x31])
            ),
            RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .success,
                domainState: Data([0x31])
            ),
        ])
        await fixture.factory.enterProfessionalWorkspace()

        let unlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(unlock, .success(.freshEvaluation))
        let signIn = await fixture.factory.beginSignIn()
        XCTAssertEqual(signIn, .started)
        XCTAssertEqual(fixture.random.requestedCounts, [32, 32])
        var snapshot = try XCTUnwrap(fixture.factory.physicalEvidenceSnapshot)
        XCTAssertTrue(snapshot.hasValidLocalProof)
        XCTAssertFalse(snapshot.isProtectedUIObscured)
        XCTAssertTrue(snapshot.hasSyntheticSessionMaterial)

        let sensitiveAction = await fixture.factory.requestLocalUnlock(
            purpose: .sensitiveAction
        )
        XCTAssertEqual(sensitiveAction, .success(.freshEvaluation))
        XCTAssertEqual(fixture.authenticationContexts.makeCount, 2)

        fixture.factory.handleLifecycle(.background)

        snapshot = try XCTUnwrap(fixture.factory.physicalEvidenceSnapshot)
        XCTAssertFalse(snapshot.hasValidLocalProof)
        XCTAssertTrue(snapshot.isProtectedUIObscured)
        XCTAssertFalse(snapshot.hasSyntheticSessionMaterial)
    }

    func testPhysicalProfessionalEvidencePendingKeychainCreateLoadClearNotFoundAndRedeemFlows() async throws {
        let fixture = makePhysicalProfessionalEvidenceFixture(contexts: [
            RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .success,
                domainState: Data([0x41])
            ),
        ])
        await fixture.factory.enterProfessionalWorkspace()
        let unlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(unlock, .success(.freshEvaluation))

        let firstRequest = await fixture.factory.requestMagicLink(
            email: PhysicalProfessionalEvidenceHarness.syntheticEmail
        )
        XCTAssertEqual(firstRequest, .requested)
        XCTAssertEqual(fixture.random.requestedCounts, [32, 32])
        XCTAssertNotNil(fixture.store.value)
        XCTAssertTrue(
            try XCTUnwrap(fixture.factory.physicalEvidenceSnapshot)
                .hasPendingCompletion
        )
        XCTAssertEqual(
            fixture.factory.inspectPhysicalEvidencePendingItem(),
            .found
        )
        XCTAssertEqual(
            fixture.factory.clearPhysicalEvidencePendingItem(),
            .cleared
        )
        XCTAssertNil(fixture.store.value)
        XCTAssertEqual(
            fixture.factory.inspectPhysicalEvidencePendingItem(),
            .itemNotFound
        )

        let secondRequest = await fixture.factory.requestMagicLink(
            email: PhysicalProfessionalEvidenceHarness.syntheticEmail
        )
        XCTAssertEqual(secondRequest, .requested)
        let redemption = await fixture.factory.redeemMagicLink(
            transferCode: PhysicalProfessionalEvidenceHarness.syntheticTransferCode
        )
        XCTAssertEqual(redemption, .completed)
        XCTAssertNil(fixture.store.value)
        let completed = try XCTUnwrap(fixture.factory.physicalEvidenceSnapshot)
        XCTAssertFalse(completed.hasPendingCompletion)
        XCTAssertTrue(completed.hasSyntheticSessionMaterial)
        XCTAssertEqual(fixture.random.requestedCounts, [32, 32, 32, 32, 32, 32])
    }

    func testPhysicalProfessionalEvidenceUsesSecureRandomLocalAdaptersAndNoTransportOrLoggingSurface() throws {
        let first = try ProfessionalMagicLinkSecureRandom.bytes(count: 32)
        let second = try ProfessionalMagicLinkSecureRandom.bytes(count: 32)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(second.count, 32)
        XCTAssertNotEqual(first, second)

        let harnessURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Professional/PhysicalProfessionalEvidenceHarness.swift")
        let source = try String(contentsOf: harnessURL, encoding: .utf8)
        for required in [
            "AppleDeviceAuthenticationContextFactory()",
            "KeychainMagicLinkTransientStateStore(",
            "ProfessionalMagicLinkSecureRandom.bytes",
        ] {
            XCTAssertTrue(source.contains(required), "Missing real local adapter: \(required)")
        }
        for forbidden in [
            "URLSession",
            "FoundationProfessionalHTTPTransport",
            "ProfessionalTelemetryClient",
            "ProfessionalRemoteConfigurationClient",
            "Cognito",
            "AWS",
            "Stripe",
            "Logger(",
            "print(",
            "NSLog(",
            "os_log(",
            "Data(repeating:",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden harness surface: \(forbidden)")
        }
    }
#endif

    func testProductionProfessionalHTTPTransportReportsAttemptThroughInjectedBoundaryBeforeIO() async throws {
        let observer = RecordingProfessionalTransportObserver(shouldBlock: true)
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = FoundationProfessionalHTTPTransport(
            session: session,
            observerFactory: .observing(observer)
        )
        let url = try XCTUnwrap(
            URL(string: "https://offline-guard.invalid/professional-positive-control")
        )

        do {
            _ = try await transport.send(ProfessionalHTTPRequest(url: url))
            XCTFail("The injected forbidden observer must stop the production transport path.")
        } catch is TestProfessionalTransportBlocked {
            // Expected: the sole production transport reports before URLSession I/O.
        }

        XCTAssertEqual(
            observer.attempts,
            [ProfessionalTransportAttempt(url: url, method: "GET")]
        )
    }

    func testSuccessfulUnlockUsesEvaluationAfterPreflightAndFreshContextPerAttempt() async {
        let first = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x01])
        )
        let second = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x01])
        )
        let contexts = RecordingDeviceAuthenticationContextFactory(contexts: [first, second])
        let coordinator = DeviceAuthenticationCoordinator(contextFactory: contexts)

        let firstResult = await coordinator.authenticate(
            reason: "Unlock professional workspace with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        let secondResult = await coordinator.authenticate(
            reason: "Confirm this sensitive action with Face ID or device passcode.",
            purpose: .sensitiveAction
        )

        XCTAssertEqual(firstResult, .success(.freshEvaluation))
        XCTAssertEqual(secondResult, .success(.freshEvaluation))
        XCTAssertEqual(first.preflightCount, 1)
        XCTAssertEqual(first.evaluationCount, 1)
        XCTAssertEqual(second.preflightCount, 1)
        XCTAssertEqual(second.evaluationCount, 1)
        XCTAssertEqual(contexts.makeCount, 2)
        XCTAssertFalse(coordinator.isProtectedUIObscured)
    }

    func testEvaluationOutcomesModelCancellationFailureAndPasscodeFallback() async {
        let cases: [(DeviceAuthenticationFailure, DeviceAuthenticationOutcome)] = [
            (.userCancellation, .userCancellation),
            (.appCancellation, .appCancellation),
            (.systemCancellation, .systemCancellation),
            (.authenticationFailed, .authenticationFailed),
            (.passcodeFallbackRequired, .passcodeFallbackRequired),
        ]

        for (failure, expected) in cases {
            let context = RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .failure(failure),
                domainState: nil
            )
            let coordinator = DeviceAuthenticationCoordinator(
                contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [context])
            )

            let result = await coordinator.authenticate(
                reason: "Use Face ID or device passcode.",
                purpose: .workspaceUnlock
            )

            XCTAssertEqual(result, expected)
            XCTAssertTrue(coordinator.isProtectedUIObscured)
        }
    }

    func testPreflightUnavailableNotEnrolledAndNoPasscodeNeverCountAsSuccess() async {
        let cases: [(DeviceAuthenticationFailure, DeviceAuthenticationOutcome)] = [
            (.unavailable, .unavailable),
            (.notEnrolled, .notEnrolled),
            (.noPasscode, .noPasscode),
        ]

        for (failure, expected) in cases {
            let context = RecordingDeviceAuthenticationContext(
                preflight: .failure(failure),
                evaluation: .success,
                domainState: Data([0x01])
            )
            let coordinator = DeviceAuthenticationCoordinator(
                contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [context])
            )

            let result = await coordinator.authenticate(
                reason: "Use Face ID or device passcode.",
                purpose: .workspaceUnlock
            )

            XCTAssertEqual(result, expected)
            XCTAssertEqual(context.evaluationCount, 0, "Preflight is not success evidence.")
            XCTAssertFalse(coordinator.hasValidLocalProof())
            XCTAssertTrue(coordinator.isProtectedUIObscured)
        }
    }

    func testWorkspaceProofExpiresAtFiveMinutesAndSensitiveActionAlwaysEvaluatesFresh() async {
        let clock = MutableDateSource(Date(timeIntervalSince1970: 1_800_000_000))
        let first = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x10])
        )
        let sensitive = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x10])
        )
        let stale = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x10])
        )
        let contexts = RecordingDeviceAuthenticationContextFactory(
            contexts: [first, sensitive, stale]
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: contexts,
            now: { clock.now },
            maximumLocalProofAge: 900
        )

        let initialUnlock = await coordinator.authenticate(
            reason: "Unlock with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        clock.now.addTimeInterval(299)
        let recentUnlock = await coordinator.authenticate(
            reason: "Unlock with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        XCTAssertEqual(recentUnlock, .success(.recentLocalProof))
        XCTAssertEqual(contexts.makeCount, 1)

        let sensitiveConfirmation = await coordinator.authenticate(
            reason: "Confirm with Face ID or device passcode.",
            purpose: .sensitiveAction
        )
        XCTAssertEqual(sensitiveConfirmation, .success(.freshEvaluation))
        XCTAssertEqual(contexts.makeCount, 2)

        clock.now.addTimeInterval(2)
        let staleUnlock = await coordinator.authenticate(
            reason: "Unlock with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        XCTAssertEqual(staleUnlock, .success(.freshEvaluation))
        XCTAssertEqual(contexts.makeCount, 3)
    }

    func testExpiredProofRelocksProtectedUIAndBlocksDirectSignInWithoutStartingSession() async {
        let clock = MutableDateSource(Date(timeIntervalSince1970: 1_800_000_000))
        let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
        let session = RecordingProfessionalSessionClient()
        let unlock = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x11])
        )
        let secondUnlock = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x11])
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(
                contexts: [unlock, secondUnlock]
            ),
            now: { clock.now },
            maximumLocalProofAge: 900
        )
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: availability,
                    sessionClient: session,
                    deviceAuthentication: coordinator
                )
            }
        )

        await factory.enterProfessionalWorkspace()
        let unlockResult = await factory.requestLocalUnlock()
        XCTAssertEqual(unlockResult, .success(.freshEvaluation))
        session.seedCommittedSessionMaterial(
            plaintext: Data("client-session".utf8),
            wrapped: Data("client-wrapped".utf8)
        )
        coordinator.recordPlaintextProfessionalSessionMaterial(Data("session".utf8))
        coordinator.recordWrappedProfessionalMaterial(Data("wrapped".utf8))
        clock.now.addTimeInterval(301)

        let signIn = await factory.beginSignIn()

        XCTAssertEqual(
            signIn,
            .unavailable(
                "Unlock the professional workspace with Face ID or device passcode before signing in."
            )
        )
        XCTAssertEqual(session.beginSignInCount, 0)
        XCTAssertTrue(coordinator.requiresLocalUnlock)
        XCTAssertTrue(coordinator.isProtectedUIObscured)
        XCTAssertTrue(factory.isProtectedUIObscured)
        XCTAssertFalse(session.hasCommittedPlaintextSessionMaterial)
        XCTAssertFalse(session.hasCommittedWrappedSessionMaterial)
        XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)

        let secondUnlockResult = await factory.requestLocalUnlock()
        XCTAssertEqual(secondUnlockResult, .success(.freshEvaluation))
        session.seedCommittedSessionMaterial(
            plaintext: Data("client-session-2".utf8),
            wrapped: Data("client-wrapped-2".utf8)
        )
        coordinator.recordPlaintextProfessionalSessionMaterial(Data("session-2".utf8))
        coordinator.recordWrappedProfessionalMaterial(Data("wrapped-2".utf8))
        clock.now.addTimeInterval(301)

        XCTAssertFalse(factory.refreshProtectedState())
        XCTAssertTrue(factory.isProtectedUIObscured)
        XCTAssertTrue(coordinator.requiresLocalUnlock)
        XCTAssertFalse(session.hasCommittedPlaintextSessionMaterial)
        XCTAssertFalse(session.hasCommittedWrappedSessionMaterial)
        XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
    }

    func testExpiredProofBeforeImmediateReauthenticationClearsOldSessionAndRequiresNewSignIn() async {
        let clock = MutableDateSource(Date(timeIntervalSince1970: 1_800_000_000))
        let initialUnlock = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x13])
        )
        let freshUnlock = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x13])
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(
                contexts: [initialUnlock, freshUnlock]
            ),
            now: { clock.now },
            maximumLocalProofAge: 900
        )
        let session = InterleavingProfessionalSessionClient()
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: RecordingProfessionalAvailabilityClient(
                        result: .enabled
                    ),
                    sessionClient: session,
                    deviceAuthentication: coordinator
                )
            }
        )

        await factory.enterProfessionalWorkspace()
        let initialUnlockResult = await factory.requestLocalUnlock()
        XCTAssertEqual(initialUnlockResult, .success(.freshEvaluation))
        session.seedCommittedSessionMaterial(
            plaintext: Data("old-client-session".utf8),
            wrapped: Data("old-client-wrapped".utf8)
        )
        coordinator.recordPlaintextProfessionalSessionMaterial(
            Data("old-coordinator-session".utf8)
        )
        coordinator.recordWrappedProfessionalMaterial(
            Data("old-coordinator-wrapped".utf8)
        )
        let expiredOperation = Task { @MainActor in
            await factory.beginSignIn()
        }
        await session.waitUntilSignInCount(1)
        clock.now.addTimeInterval(301)

        let reauthentication = await factory.requestLocalUnlock()

        XCTAssertEqual(reauthentication, .success(.freshEvaluation))
        XCTAssertEqual(session.clearPlaintextSessionCount, 1)
        XCTAssertNil(session.committedPlaintextSessionMaterial)
        XCTAssertNil(session.committedWrappedSessionMaterial)
        XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
        XCTAssertEqual(Set(session.discardedOperationIDs).count, 1)
        XCTAssertTrue(coordinator.hasValidLocalProof())
        XCTAssertFalse(factory.isProtectedUIObscured)

        guard session.clearPlaintextSessionCount == 1,
              session.committedPlaintextSessionMaterial == nil,
              coordinator.hasValidLocalProof()
        else {
            session.completeSignIn(at: 0, material: "red-cleanup")
            _ = await expiredOperation.value
            return
        }

        let replacementOperation = Task { @MainActor in
            await factory.beginSignIn()
        }
        await session.waitUntilSignInCount(2)
        session.completeSignIn(at: 1, material: "replacement-session")
        let replacementResult = await replacementOperation.value
        XCTAssertEqual(replacementResult, .started)
        session.completeSignIn(at: 0, material: "expired-session")
        let expiredResult = await expiredOperation.value
        XCTAssertNotEqual(expiredResult, .started)

        XCTAssertEqual(session.beginSignInCount, 2)
        XCTAssertEqual(session.clearPlaintextSessionCount, 1)
        XCTAssertEqual(
            session.committedPlaintextSessionMaterial,
            Data("replacement-session".utf8)
        )
        XCTAssertEqual(
            session.committedWrappedSessionMaterial,
            Data("wrapped-replacement-session".utf8)
        )
        XCTAssertTrue(coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertTrue(coordinator.hasWrappedProfessionalMaterial)
        XCTAssertTrue(coordinator.hasValidLocalProof())
        XCTAssertFalse(factory.isProtectedUIObscured)
    }

    func testExpiredProofBeforeFailedOrCancelledReauthenticationClearsOnceAndStaysLocked() async {
        let cases: [(
            failure: DeviceAuthenticationFailure,
            outcome: DeviceAuthenticationOutcome
        )] = [
            (.userCancellation, .userCancellation),
            (.authenticationFailed, .authenticationFailed),
        ]

        for testCase in cases {
            let clock = MutableDateSource(Date(timeIntervalSince1970: 1_800_000_000))
            let initialUnlock = RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .success,
                domainState: Data([0x14])
            )
            let failedReauthentication = RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .failure(testCase.failure),
                domainState: Data([0x14])
            )
            let coordinator = DeviceAuthenticationCoordinator(
                contextFactory: RecordingDeviceAuthenticationContextFactory(
                    contexts: [initialUnlock, failedReauthentication]
                ),
                now: { clock.now },
                maximumLocalProofAge: 900
            )
            let session = RecordingProfessionalSessionClient()
            let factory = ProfessionalEnvironmentFactory(
                localConfiguration: .enabled,
                makeEnvironment: {
                    ProfessionalEnvironment(
                        availabilityClient: RecordingProfessionalAvailabilityClient(
                            result: .enabled
                        ),
                        sessionClient: session,
                        deviceAuthentication: coordinator
                    )
                }
            )

            await factory.enterProfessionalWorkspace()
            let initialUnlockResult = await factory.requestLocalUnlock()
            XCTAssertEqual(initialUnlockResult, .success(.freshEvaluation))
            session.seedCommittedSessionMaterial(
                plaintext: Data("old-client-session".utf8),
                wrapped: Data("old-client-wrapped".utf8)
            )
            coordinator.recordPlaintextProfessionalSessionMaterial(
                Data("old-coordinator-session".utf8)
            )
            coordinator.recordWrappedProfessionalMaterial(
                Data("old-coordinator-wrapped".utf8)
            )
            clock.now.addTimeInterval(301)

            let outcome = await factory.requestLocalUnlock()

            XCTAssertEqual(outcome, testCase.outcome)
            XCTAssertEqual(session.clearPlaintextSessionCount, 1)
            XCTAssertFalse(session.hasCommittedPlaintextSessionMaterial)
            XCTAssertFalse(session.hasCommittedWrappedSessionMaterial)
            XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
            XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
            XCTAssertFalse(coordinator.hasValidLocalProof())
            XCTAssertTrue(coordinator.requiresLocalUnlock)
            XCTAssertTrue(factory.isProtectedUIObscured)
            XCTAssertFalse(factory.refreshProtectedState())
            XCTAssertEqual(session.clearPlaintextSessionCount, 1)
            XCTAssertEqual(session.beginSignInCount, 0)
            XCTAssertTrue(session.discardedOperationIDs.isEmpty)
        }
    }

    func testUnavailableSecurityPostureAfterUnlockRevokesBothMaterialOwnersAndBlocksSignIn() async {
        let postureChanges: [(
            failure: DeviceAuthenticationFailure,
            outcome: DeviceAuthenticationOutcome
        )] = [
            (.noPasscode, .noPasscode),
            (.unavailable, .unavailable),
            (.notEnrolled, .notEnrolled),
        ]

        for postureChange in postureChanges {
            let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
            let session = RecordingProfessionalSessionClient()
            let unlock = RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .success,
                domainState: Data([0x12])
            )
            let unavailablePosture = RecordingDeviceAuthenticationContext(
                preflight: .failure(postureChange.failure),
                evaluation: .success,
                domainState: nil
            )
            let coordinator = DeviceAuthenticationCoordinator(
                contextFactory: RecordingDeviceAuthenticationContextFactory(
                    contexts: [unlock, unavailablePosture]
                )
            )
            let factory = ProfessionalEnvironmentFactory(
                localConfiguration: .enabled,
                makeEnvironment: {
                    ProfessionalEnvironment(
                        availabilityClient: availability,
                        sessionClient: session,
                        deviceAuthentication: coordinator
                    )
                }
            )

            await factory.enterProfessionalWorkspace()
            let initialUnlock = await factory.requestLocalUnlock()
            XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
            session.seedCommittedSessionMaterial(
                plaintext: Data("client-session".utf8),
                wrapped: Data("client-wrapped".utf8)
            )
            coordinator.recordPlaintextProfessionalSessionMaterial(Data("session".utf8))
            coordinator.recordWrappedProfessionalMaterial(Data("wrapped".utf8))

            let postureResult = await factory.requestLocalUnlock(
                purpose: .sensitiveAction
            )
            let signIn = await factory.beginSignIn()

            XCTAssertEqual(postureResult, postureChange.outcome)
            XCTAssertNotEqual(signIn, .started)
            XCTAssertEqual(session.beginSignInCount, 0)
            XCTAssertFalse(session.hasCommittedPlaintextSessionMaterial)
            XCTAssertFalse(session.hasCommittedWrappedSessionMaterial)
            XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
            XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
            XCTAssertTrue(coordinator.requiresLocalUnlock)
            XCTAssertTrue(factory.isProtectedUIObscured)
            XCTAssertFalse(factory.refreshProtectedState())
        }
    }

    func testInactiveObscuresProtectedUIAndCancelsPendingEvaluation() async {
        let context = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: nil,
            domainState: nil
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [context])
        )
        let pending = Task { @MainActor in
            await coordinator.authenticate(
                reason: "Unlock with Face ID or device passcode.",
                purpose: .workspaceUnlock
            )
        }
        await Task.yield()

        coordinator.handleLifecycle(.inactive)
        let result = await pending.value

        XCTAssertEqual(result, .appCancellation)
        XCTAssertTrue(context.wasInvalidated)
        XCTAssertTrue(coordinator.isProtectedUIObscured)
    }

    func testBackgroundClearsPlaintextSessionAndRequiresFreshUnlockOnForeground() async {
        let context = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x20])
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [context])
        )
        _ = await coordinator.authenticate(
            reason: "Unlock with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        coordinator.recordPlaintextProfessionalSessionMaterial(Data("session".utf8))

        coordinator.handleLifecycle(.background)
        coordinator.handleLifecycle(.foreground)

        XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertFalse(coordinator.hasValidLocalProof())
        XCTAssertTrue(coordinator.requiresLocalUnlock)
        XCTAssertTrue(coordinator.isProtectedUIObscured)
        XCTAssertTrue(context.wasInvalidated)
    }

    func testBackgroundDiscardsCancellationInsensitiveLateSignInSuccessAndClearsMaterial() async {
        let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
        let unlock = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x21])
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [unlock])
        )
        let session = SuspendedProfessionalSessionClient()
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: availability,
                    sessionClient: session,
                    deviceAuthentication: coordinator
                )
            }
        )

        await factory.enterProfessionalWorkspace()
        let unlockResult = await factory.requestLocalUnlock()
        XCTAssertEqual(unlockResult, .success(.freshEvaluation))
        let pendingSignIn = Task { @MainActor in
            await factory.beginSignIn()
        }
        await session.waitUntilSignInIsSuspended()

        factory.handleLifecycle(.background)
        session.completeSuccessfullyIgnoringCancellation()
        let result = await pendingSignIn.value

        XCTAssertNotEqual(result, .started)
        XCTAssertTrue(session.didObserveTaskCancellation)
        XCTAssertFalse(session.hasPlaintextSessionMaterial)
        XCTAssertGreaterThanOrEqual(session.clearPlaintextSessionCount, 1)
        XCTAssertGreaterThanOrEqual(session.discardedOperationIDs.count, 1)
        XCTAssertEqual(Set(session.discardedOperationIDs).count, 1)
        XCTAssertFalse(coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
        XCTAssertTrue(coordinator.requiresLocalUnlock)
        XCTAssertTrue(factory.isProtectedUIObscured)
    }

    func testStaleSignInCompletionCannotClearNewerCommittedSession() async {
        let fixture = makeInterleavingSignInFixture(authenticationContextCount: 2)
        await fixture.factory.enterProfessionalWorkspace()
        let initialUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        let oldSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(1)

        fixture.factory.handleLifecycle(.background)
        fixture.factory.handleLifecycle(.foreground)
        let secondUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(secondUnlock, .success(.freshEvaluation))
        let newSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(2)

        fixture.session.completeSignIn(at: 1, material: "new-session")
        let newResult = await newSignIn.value
        XCTAssertEqual(newResult, .started)
        fixture.session.completeSignIn(at: 0, material: "old-session")
        let oldResult = await oldSignIn.value
        XCTAssertNotEqual(oldResult, .started)

        XCTAssertEqual(
            fixture.session.committedPlaintextSessionMaterial,
            Data("new-session".utf8)
        )
        XCTAssertTrue(fixture.coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertTrue(fixture.coordinator.hasWrappedProfessionalMaterial)
        XCTAssertTrue(fixture.coordinator.hasValidLocalProof())
        XCTAssertFalse(fixture.factory.isProtectedUIObscured)
    }

    func testStaleSignInCompletingBeforeNewerOperationDoesNotPoisonNewCommit() async {
        let fixture = makeInterleavingSignInFixture(authenticationContextCount: 2)
        await fixture.factory.enterProfessionalWorkspace()
        let initialUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        let oldSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(1)

        fixture.factory.handleLifecycle(.background)
        fixture.factory.handleLifecycle(.foreground)
        let secondUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(secondUnlock, .success(.freshEvaluation))
        let newSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(2)

        fixture.session.completeSignIn(at: 0, material: "old-session")
        let oldResult = await oldSignIn.value
        XCTAssertNotEqual(oldResult, .started)
        XCTAssertTrue(fixture.coordinator.hasValidLocalProof())
        fixture.session.completeSignIn(at: 1, material: "new-session")
        let newResult = await newSignIn.value
        XCTAssertEqual(newResult, .started)

        XCTAssertEqual(
            fixture.session.committedPlaintextSessionMaterial,
            Data("new-session".utf8)
        )
        XCTAssertTrue(fixture.coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertTrue(fixture.coordinator.hasWrappedProfessionalMaterial)
        XCTAssertTrue(fixture.coordinator.hasValidLocalProof())
        XCTAssertFalse(fixture.factory.isProtectedUIObscured)
    }

    func testMultipleBackgroundEpochsDiscardEveryOldCompletionWithoutClearingNewestSession() async {
        let fixture = makeInterleavingSignInFixture(authenticationContextCount: 3)
        await fixture.factory.enterProfessionalWorkspace()
        let initialUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        let oldestSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(1)

        fixture.factory.handleLifecycle(.background)
        fixture.factory.handleLifecycle(.foreground)
        let secondUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(secondUnlock, .success(.freshEvaluation))
        let middleSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(2)

        fixture.factory.handleLifecycle(.background)
        fixture.factory.handleLifecycle(.foreground)
        let thirdUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(thirdUnlock, .success(.freshEvaluation))
        let newestSignIn = Task { @MainActor in
            await fixture.factory.beginSignIn()
        }
        await fixture.session.waitUntilSignInCount(3)

        fixture.session.completeSignIn(at: 2, material: "newest-session")
        let newestResult = await newestSignIn.value
        XCTAssertEqual(newestResult, .started)
        fixture.session.completeSignIn(at: 1, material: "middle-session")
        fixture.session.completeSignIn(at: 0, material: "oldest-session")
        let middleResult = await middleSignIn.value
        let oldestResult = await oldestSignIn.value
        XCTAssertNotEqual(middleResult, .started)
        XCTAssertNotEqual(oldestResult, .started)

        XCTAssertEqual(
            fixture.session.committedPlaintextSessionMaterial,
            Data("newest-session".utf8)
        )
        XCTAssertTrue(fixture.coordinator.hasPlaintextProfessionalSessionMaterial)
        XCTAssertTrue(fixture.coordinator.hasWrappedProfessionalMaterial)
        XCTAssertTrue(fixture.coordinator.hasValidLocalProof())
        XCTAssertFalse(fixture.factory.isProtectedUIObscured)
    }

    func testEvaluationCompletionPublishesOutcomeOnMainActor() async {
        let context = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x30]),
            completionQueue: DispatchQueue.global(qos: .userInitiated)
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: [context])
        )
        let published = expectation(description: "Outcome published on MainActor")
        var subscriptions = Set<AnyCancellable>()
        coordinator.$lastOutcome
            .compactMap { $0 }
            .sink { outcome in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(outcome, .success(.freshEvaluation))
                published.fulfill()
            }
            .store(in: &subscriptions)

        let result = await coordinator.authenticate(
            reason: "Unlock with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        await fulfillment(of: [published], timeout: 1)

        XCTAssertEqual(result, .success(.freshEvaluation))
        withExtendedLifetime(subscriptions) {}
    }

    func testDomainStateChangeAndNilTransitionInvalidateWrappedMaterialAndTrust() async {
        let initial = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x40])
        )
        let changed = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: Data([0x41])
        )
        let nilTransition = RecordingDeviceAuthenticationContext(
            preflight: .available,
            evaluation: .success,
            domainState: nil
        )
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(
                contexts: [initial, changed, nilTransition]
            )
        )

        let initialUnlock = await coordinator.authenticate(
            reason: "Unlock with Face ID or device passcode.",
            purpose: .workspaceUnlock
        )
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        coordinator.recordWrappedProfessionalMaterial(Data("wrapped-1".utf8))
        let changedState = await coordinator.authenticate(
            reason: "Confirm with Face ID or device passcode.",
            purpose: .sensitiveAction
        )
        XCTAssertEqual(changedState, .domainStateChanged)
        XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
        XCTAssertFalse(coordinator.hasValidLocalProof())

        coordinator.recordWrappedProfessionalMaterial(Data("wrapped-2".utf8))
        let nilState = await coordinator.authenticate(
            reason: "Confirm with Face ID or device passcode.",
            purpose: .sensitiveAction
        )
        XCTAssertEqual(nilState, .domainStateChanged)
        XCTAssertFalse(coordinator.hasWrappedProfessionalMaterial)
    }

    func testAppleErrorMappingCoversCancellationFailureFallbackAndAvailability() {
        let cases: [(LAError.Code, DeviceAuthenticationFailure)] = [
            (.userCancel, .userCancellation),
            (.appCancel, .appCancellation),
            (.systemCancel, .systemCancellation),
            (.authenticationFailed, .authenticationFailed),
            (.userFallback, .passcodeFallbackRequired),
            (.biometryLockout, .passcodeFallbackRequired),
            (.biometryNotAvailable, .unavailable),
            (.biometryNotEnrolled, .notEnrolled),
            (.passcodeNotSet, .noPasscode),
        ]

        for (code, expected) in cases {
            let error = NSError(domain: LAError.errorDomain, code: code.rawValue)
            XCTAssertEqual(
                AppleDeviceAuthenticationErrorMapper.failure(from: error),
                expected
            )
        }
    }

    func testKeychainPolicyRequiresThisDeviceWhenUnlockedAndUserPresenceWithoutStoringSecret() throws {
        let policy = ProfessionalKeychainAccessPolicy()

        XCTAssertEqual(
            policy.accessibility as String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertTrue(policy.accessControlFlags.contains(.userPresence))
        XCTAssertNotNil(try policy.makeAccessControl())
    }

    private func makeInterleavingSignInFixture(
        authenticationContextCount: Int
    ) -> (
        factory: ProfessionalEnvironmentFactory,
        session: InterleavingProfessionalSessionClient,
        coordinator: DeviceAuthenticationCoordinator
    ) {
        let contexts = (0..<authenticationContextCount).map { _ in
            RecordingDeviceAuthenticationContext(
                preflight: .available,
                evaluation: .success,
                domainState: Data([0x51])
            )
        }
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(
                contexts: contexts
            )
        )
        let session = InterleavingProfessionalSessionClient()
        let availability = RecordingProfessionalAvailabilityClient(result: .enabled)
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: availability,
                    sessionClient: session,
                    deviceAuthentication: coordinator
                )
            }
        )
        return (factory, session, coordinator)
    }

    private func makeProfessionalFactory(
        availability: RecordingProfessionalAvailabilityClient,
        session: RecordingProfessionalSessionClient,
        contexts: [RecordingDeviceAuthenticationContext]
    ) -> ProfessionalEnvironmentFactory {
        ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: availability,
                    sessionClient: session,
                    deviceAuthentication: DeviceAuthenticationCoordinator(
                        contextFactory: RecordingDeviceAuthenticationContextFactory(
                            contexts: contexts
                        )
                    )
                )
            }
        )
    }

#if DEBUG
    private func makePhysicalProfessionalEvidenceFixture(
        contexts: [RecordingDeviceAuthenticationContext]
    ) -> PhysicalProfessionalEvidenceFixture {
        let authenticationFactoryConstruction = InvocationRecorder()
        let storeConstruction = InvocationRecorder()
        let authenticationContexts = RecordingDeviceAuthenticationContextFactory(
            contexts: contexts
        )
        let store = PhysicalProfessionalEvidenceMemoryStore()
        let random = RecordingPhysicalProfessionalEvidenceRandom()
        let dependencies = PhysicalProfessionalEvidenceHarness.Dependencies(
            makeAuthenticationContextFactory: {
                authenticationFactoryConstruction.record()
                return authenticationContexts
            },
            makeTransientStateStore: {
                storeConstruction.record()
                return store
            },
            randomBytes: random.bytes(count:)
        )
        return PhysicalProfessionalEvidenceFixture(
            factory: PhysicalProfessionalEvidenceHarness.factory(
                arguments: [
                    "RoomScanStudio",
                    "--ui-testing",
                    "--physical-professional-evidence",
                ],
                isDebugBuild: true,
                isPhysicalDevice: true,
                dependencies: dependencies
            ),
            authenticationFactoryConstruction: authenticationFactoryConstruction,
            storeConstruction: storeConstruction,
            authenticationContexts: authenticationContexts,
            store: store,
            random: random
        )
    }
#endif

    func testMagicRedeemBackgroundBeforeInstallerLeavesPendingForIdenticalRetry() async throws {
        let fixture = makeMagicLifecycleFixture(suspendRedeem: true, suspendInstall: false)
        await fixture.factory.enterProfessionalWorkspace()
        let initialUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        let requested = await fixture.factory.requestMagicLink(email: "pro@example.com")
        XCTAssertEqual(requested, .requested)
        let first = Task { @MainActor in await fixture.factory.redeemMagicLink(transferCode: "ABCDEFGH") }
        await fixture.client.waitForRedeem()
        fixture.factory.handleLifecycle(.background)
        fixture.client.completeRedeem()
        let firstResult = await first.value
        XCTAssertNotEqual(firstResult, .completed)
        XCTAssertEqual(fixture.session.commitCount, 0)
        XCTAssertTrue(fixture.store.hasPending)
        fixture.factory.handleLifecycle(.foreground)
        let retryUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(retryUnlock, .success(.freshEvaluation))
        let retry = await fixture.factory.redeemMagicLink(transferCode: "ABCDEFGH")
        XCTAssertEqual(retry, .completed)
        XCTAssertEqual(fixture.session.commitCount, 1)
        XCTAssertFalse(fixture.store.hasPending)
    }

    func testMagicInstallerLateCompletionCannotCommitAfterBackgroundAndRetryIsStable() async throws {
        let fixture = makeMagicLifecycleFixture(suspendRedeem: false, suspendInstall: true)
        await fixture.factory.enterProfessionalWorkspace()
        let initialUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(initialUnlock, .success(.freshEvaluation))
        let requested = await fixture.factory.requestMagicLink(email: "pro@example.com")
        XCTAssertEqual(requested, .requested)
        let first = Task { @MainActor in await fixture.factory.redeemMagicLink(transferCode: "ABCDEFGH") }
        await fixture.session.waitForMagicInstall()
        fixture.factory.handleLifecycle(.background)
        fixture.session.completeMagicInstall()
        let firstResult = await first.value
        XCTAssertNotEqual(firstResult, .completed)
        XCTAssertEqual(fixture.session.commitCount, 0)
        XCTAssertTrue(fixture.store.hasPending)
        fixture.factory.handleLifecycle(.foreground)
        let retryUnlock = await fixture.factory.requestLocalUnlock()
        XCTAssertEqual(retryUnlock, .success(.freshEvaluation))
        let retry = await fixture.factory.redeemMagicLink(transferCode: "ABCDEFGH")
        XCTAssertEqual(retry, .completed)
        XCTAssertEqual(fixture.session.commitCount, 1)
        XCTAssertEqual(fixture.session.installInputs.count, 2)
        XCTAssertEqual(fixture.session.installInputs[0].access, fixture.session.installInputs[1].access)
        XCTAssertEqual(fixture.session.installInputs[0].refresh, fixture.session.installInputs[1].refresh)
        XCTAssertFalse(fixture.store.hasPending)
    }

    private func makeMagicLifecycleFixture(
        suspendRedeem: Bool,
        suspendInstall: Bool
    ) -> MagicLifecycleFixture {
        let client = MagicLifecycleClient(suspendFirstRedeem: suspendRedeem)
        let store = MagicLifecycleStore()
        let completion = MagicLinkCompletionCoordinator(
            client: client,
            store: store,
            randomBytes: { Data(repeating: 0x5A, count: $0) },
            now: Date.init
        )
        let session = MagicLifecycleSessionClient(suspendFirstInstall: suspendInstall)
        let contexts = [
            RecordingDeviceAuthenticationContext(preflight: .available, evaluation: .success, domainState: Data([1])),
            RecordingDeviceAuthenticationContext(preflight: .available, evaluation: .success, domainState: Data([1]))
        ]
        let coordinator = DeviceAuthenticationCoordinator(
            contextFactory: RecordingDeviceAuthenticationContextFactory(contexts: contexts)
        )
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: RecordingProfessionalAvailabilityClient(result: .enabled),
                    sessionClient: session,
                    deviceAuthentication: coordinator,
                    magicLinkCompletion: completion
                )
            }
        )
        return MagicLifecycleFixture(factory: factory, client: client, session: session, store: store)
    }
}

#if DEBUG
@MainActor
private struct PhysicalProfessionalEvidenceFixture {
    let factory: ProfessionalEnvironmentFactory
    let authenticationFactoryConstruction: InvocationRecorder
    let storeConstruction: InvocationRecorder
    let authenticationContexts: RecordingDeviceAuthenticationContextFactory
    let store: PhysicalProfessionalEvidenceMemoryStore
    let random: RecordingPhysicalProfessionalEvidenceRandom
}

private final class PhysicalProfessionalEvidenceMemoryStore:
    MagicLinkTransientStateStore
{
    private(set) var value: MagicLinkPendingState?

    func save(_ state: MagicLinkPendingState) throws {
        value = state
    }

    func load() throws -> MagicLinkPendingState? {
        value
    }

    func clear() throws {
        value = nil
    }
}

@MainActor
private final class RecordingPhysicalProfessionalEvidenceRandom {
    private(set) var requestedCounts: [Int] = []
    private var invocation: UInt8 = 0

    func bytes(count: Int) throws -> Data {
        requestedCounts.append(count)
        invocation &+= 1
        return Data((0..<count).map { offset in
            invocation &+ UInt8(truncatingIfNeeded: offset)
        })
    }
}
#endif

@MainActor
private struct MagicLifecycleFixture {
    let factory: ProfessionalEnvironmentFactory
    let client: MagicLifecycleClient
    let session: MagicLifecycleSessionClient
    let store: MagicLifecycleStore
}

@MainActor
private final class MagicLifecycleStore: MagicLinkTransientStateStore {
    private var value: MagicLinkPendingState?
    var hasPending: Bool { value != nil }
    func save(_ state: MagicLinkPendingState) throws { value = state }
    func load() throws -> MagicLinkPendingState? { value }
    func clear() throws { value = nil }
}

@MainActor
private final class MagicLifecycleClient: MagicLinkCompletionClient {
    private var pendingRedeem: CheckedContinuation<MagicLinkRedemptionResponse, Error>?
    private var suspendFirstRedeem: Bool

    init(suspendFirstRedeem: Bool) { self.suspendFirstRedeem = suspendFirstRedeem }
    func requestCompletion(_ request: MagicLinkCompletionRequest) async throws -> MagicLinkCompletionResponse {
        MagicLinkCompletionResponse(completionID: Data(repeating: 0x7B, count: 32), expiresAt: .distantFuture)
    }
    func redeemCompletion(_ request: MagicLinkRedemptionRequest) async throws -> MagicLinkRedemptionResponse {
        if suspendFirstRedeem {
            suspendFirstRedeem = false
            return try await withCheckedThrowingContinuation { pendingRedeem = $0 }
        }
        return response(for: request)
    }
    func waitForRedeem() async { while pendingRedeem == nil { await Task.yield() } }
    func completeRedeem() { let pending = pendingRedeem; pendingRedeem = nil; pending?.resume(returning: MagicLinkRedemptionResponse(purpose: .signIn, expiresAt: .distantFuture, consumed: true)) }
    private func response(for request: MagicLinkRedemptionRequest) -> MagicLinkRedemptionResponse { MagicLinkRedemptionResponse(purpose: request.purpose, expiresAt: .distantFuture, consumed: true) }
}

@MainActor
private final class MagicLifecycleSessionClient: ProfessionalSessionClient, MagicLinkSessionMaterialInstalling {
    struct Input: Equatable { let access: Data; let refresh: Data }
    private var pendingInstall: CheckedContinuation<ProfessionalPreparedSession, Error>?
    private var pendingOperationID: UUID?
    private var suspendFirstInstall: Bool
    private(set) var installInputs: [Input] = []
    private(set) var commitCount = 0
    init(suspendFirstInstall: Bool) { self.suspendFirstInstall = suspendFirstInstall }
    func prepareSignIn(operationID: UUID) async throws -> ProfessionalPreparedSession { prepared(operationID) }
    func prepareMagicLinkSignIn(access: Data, refresh: Data, operationID: UUID) async throws -> ProfessionalPreparedSession {
        installInputs.append(Input(access: access, refresh: refresh))
        if suspendFirstInstall {
            suspendFirstInstall = false
            pendingOperationID = operationID
            return try await withCheckedThrowingContinuation { pendingInstall = $0 }
        }
        return prepared(operationID)
    }
    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession) { commitCount += 1 }
    func discardPreparedSession(operationID: UUID) {}
    func clearCommittedSessionMaterial() {}
    func waitForMagicInstall() async { while pendingInstall == nil { await Task.yield() } }
    func completeMagicInstall() { let pending = pendingInstall; let operationID = pendingOperationID; pendingInstall = nil; pendingOperationID = nil; if let operationID { pending?.resume(returning: prepared(operationID)) } }
    private func prepared(_ operationID: UUID) -> ProfessionalPreparedSession { ProfessionalPreparedSession(operationID: operationID, plaintextMaterial: Data("session".utf8), wrappedMaterial: Data("wrapped".utf8)) }
}

@MainActor
private final class InvocationRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class RecordingProfessionalAvailabilityClient: ProfessionalAvailabilityClient {
    let result: ProfessionalAvailability
    private(set) var fetchCount = 0

    init(result: ProfessionalAvailability) {
        self.result = result
    }

    func fetchAvailability() async throws -> ProfessionalAvailability {
        fetchCount += 1
        return result
    }
}

@MainActor
private final class RecordingProfessionalSessionClient: ProfessionalSessionClient {
    private(set) var beginSignInCount = 0
    private(set) var clearPlaintextSessionCount = 0
    private(set) var committedPlaintextSessionMaterial: Data?
    private(set) var committedWrappedSessionMaterial: Data?

    var hasCommittedPlaintextSessionMaterial: Bool {
        committedPlaintextSessionMaterial != nil
    }

    var hasCommittedWrappedSessionMaterial: Bool {
        committedWrappedSessionMaterial != nil
    }

    private(set) var discardedOperationIDs: [UUID] = []

    func prepareSignIn(
        operationID: UUID
    ) async throws -> ProfessionalPreparedSession {
        beginSignInCount += 1
        return ProfessionalPreparedSession(
            operationID: operationID,
            plaintextMaterial: Data("prepared-session-\(beginSignInCount)".utf8),
            wrappedMaterial: Data("prepared-wrapped-\(beginSignInCount)".utf8)
        )
    }

    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession) {
        committedPlaintextSessionMaterial = preparedSession.plaintextMaterial
        committedWrappedSessionMaterial = preparedSession.wrappedMaterial
    }

    func discardPreparedSession(operationID: UUID) {
        discardedOperationIDs.append(operationID)
    }

    func clearCommittedSessionMaterial() {
        clearPlaintextSessionCount += 1
        committedPlaintextSessionMaterial = nil
        committedWrappedSessionMaterial = nil
    }

    func seedCommittedSessionMaterial(plaintext: Data, wrapped: Data?) {
        committedPlaintextSessionMaterial = plaintext
        committedWrappedSessionMaterial = wrapped
    }
}

@MainActor
private final class SuspendedProfessionalSessionClient: ProfessionalSessionClient {
    private var continuation: CheckedContinuation<ProfessionalPreparedSession, Error>?
    private var operationID: UUID?
    private(set) var clearPlaintextSessionCount = 0
    private(set) var hasPlaintextSessionMaterial = false
    private(set) var didObserveTaskCancellation = false
    private(set) var discardedOperationIDs: [UUID] = []

    func prepareSignIn(
        operationID: UUID
    ) async throws -> ProfessionalPreparedSession {
        self.operationID = operationID
        let preparedSession = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        didObserveTaskCancellation = Task.isCancelled
        return preparedSession
    }

    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession) {
        hasPlaintextSessionMaterial = true
    }

    func discardPreparedSession(operationID: UUID) {
        discardedOperationIDs.append(operationID)
    }

    func clearCommittedSessionMaterial() {
        clearPlaintextSessionCount += 1
        hasPlaintextSessionMaterial = false
    }

    func waitUntilSignInIsSuspended() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func completeSuccessfullyIgnoringCancellation() {
        let pending = continuation
        continuation = nil
        guard let operationID else { return }
        pending?.resume(
            returning: ProfessionalPreparedSession(
                operationID: operationID,
                plaintextMaterial: Data("late-session".utf8),
                wrappedMaterial: Data("late-wrapped".utf8)
            )
        )
    }
}

@MainActor
private final class InterleavingProfessionalSessionClient: ProfessionalSessionClient {
    private struct PendingSignIn {
        let index: Int
        let operationID: UUID
        let continuation: CheckedContinuation<ProfessionalPreparedSession, Error>
    }

    private var pendingSignIns: [Int: PendingSignIn] = [:]
    private(set) var beginSignInCount = 0
    private(set) var clearPlaintextSessionCount = 0
    private(set) var didObserveCancellation: [Int: Bool] = [:]
    private(set) var committedPlaintextSessionMaterial: Data?
    private(set) var committedWrappedSessionMaterial: Data?
    private(set) var discardedOperationIDs: [UUID] = []

    func prepareSignIn(
        operationID: UUID
    ) async throws -> ProfessionalPreparedSession {
        let index = beginSignInCount
        beginSignInCount += 1
        let preparedSession = try await withCheckedThrowingContinuation { continuation in
            pendingSignIns[index] = PendingSignIn(
                index: index,
                operationID: operationID,
                continuation: continuation
            )
        }
        didObserveCancellation[index] = Task.isCancelled
        return preparedSession
    }

    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession) {
        committedPlaintextSessionMaterial = preparedSession.plaintextMaterial
        committedWrappedSessionMaterial = preparedSession.wrappedMaterial
    }

    func discardPreparedSession(operationID: UUID) {
        discardedOperationIDs.append(operationID)
    }

    func clearCommittedSessionMaterial() {
        clearPlaintextSessionCount += 1
        committedPlaintextSessionMaterial = nil
        committedWrappedSessionMaterial = nil
    }

    func seedCommittedSessionMaterial(plaintext: Data, wrapped: Data?) {
        committedPlaintextSessionMaterial = plaintext
        committedWrappedSessionMaterial = wrapped
    }

    func waitUntilSignInCount(_ expectedCount: Int) async {
        while beginSignInCount < expectedCount {
            await Task.yield()
        }
    }

    func completeSignIn(at index: Int, material: String) {
        let pending = pendingSignIns.removeValue(forKey: index)
        guard let pending else { return }
        pending.continuation.resume(
            returning: ProfessionalPreparedSession(
                operationID: pending.operationID,
                plaintextMaterial: Data(material.utf8),
                wrappedMaterial: Data("wrapped-\(material)".utf8)
            )
        )
    }
}

private final class MutableDateSource: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private struct TestProfessionalTransportBlocked: Error {}

private final class RecordingProfessionalTransportObserver:
    ProfessionalTransportRequestObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let shouldBlock: Bool
    private var recordedAttempts: [ProfessionalTransportAttempt] = []

    init(shouldBlock: Bool = false) {
        self.shouldBlock = shouldBlock
    }

    var attempts: [ProfessionalTransportAttempt] {
        lock.withLock { recordedAttempts }
    }

    func observe(_ attempt: ProfessionalTransportAttempt) throws {
        try lock.withLock {
            recordedAttempts.append(attempt)
            if shouldBlock {
                throw TestProfessionalTransportBlocked()
            }
        }
    }
}

private final class RecordingDeviceAuthenticationContextFactory:
    DeviceAuthenticationContextFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var contexts: [RecordingDeviceAuthenticationContext]
    private var recordedMakeCount = 0

    init(contexts: [RecordingDeviceAuthenticationContext]) {
        self.contexts = contexts
    }

    var makeCount: Int {
        lock.withLock { recordedMakeCount }
    }

    func makeContext() -> any DeviceAuthenticationContext {
        lock.withLock {
            recordedMakeCount += 1
            precondition(!contexts.isEmpty, "Test requested more authentication contexts than provided.")
            return contexts.removeFirst()
        }
    }
}

private final class RecordingDeviceAuthenticationContext:
    DeviceAuthenticationContext,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let preflightResult: DeviceAuthenticationPreflight
    private let evaluationResult: DeviceAuthenticationEvaluation?
    private let completionQueue: DispatchQueue?
    private var pendingCompletion: ((DeviceAuthenticationEvaluation) -> Void)?
    private var recordedPreflightCount = 0
    private var recordedEvaluationCount = 0
    private var recordedInvalidated = false
    let evaluatedDomainState: Data?

    init(
        preflight: DeviceAuthenticationPreflight,
        evaluation: DeviceAuthenticationEvaluation?,
        domainState: Data?,
        completionQueue: DispatchQueue? = nil
    ) {
        preflightResult = preflight
        evaluationResult = evaluation
        evaluatedDomainState = domainState
        self.completionQueue = completionQueue
    }

    var preflightCount: Int {
        lock.withLock { recordedPreflightCount }
    }

    var evaluationCount: Int {
        lock.withLock { recordedEvaluationCount }
    }

    var wasInvalidated: Bool {
        lock.withLock { recordedInvalidated }
    }

    func preflight() -> DeviceAuthenticationPreflight {
        lock.withLock {
            recordedPreflightCount += 1
            return preflightResult
        }
    }

    func evaluate(
        reason: String,
        completion: @escaping @Sendable (DeviceAuthenticationEvaluation) -> Void
    ) {
        let result: DeviceAuthenticationEvaluation? = lock.withLock {
            recordedEvaluationCount += 1
            guard let evaluationResult else {
                pendingCompletion = completion
                return nil
            }
            return evaluationResult
        }
        guard let result else { return }
        if let completionQueue {
            completionQueue.async {
                completion(result)
            }
        } else {
            completion(result)
        }
    }

    func invalidate() {
        let completion: ((DeviceAuthenticationEvaluation) -> Void)? = lock.withLock {
            recordedInvalidated = true
            defer { pendingCompletion = nil }
            return pendingCompletion
        }
        completion?(.failure(.appCancellation))
    }
}
