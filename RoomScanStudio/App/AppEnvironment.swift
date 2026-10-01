import Combine
import Foundation
import SwiftData
import RoomScanCore
import UIKit

@MainActor
final class AppEnvironment: ObservableObject {
    let capabilityProvider: any DeviceCapabilityProviding
    let libraryController: RoomLibraryController
    let rescanProvider: any RoomRescanProviding
    let exportCoordinator: RoomExportCoordinator
    let aiRedesignModelFactory: RoomAIRedesignModelFactory
    let cloudBackupCoordinator: RoomCloudBackupCoordinator
    let meshColoringCoordinator: RoomMeshColoringJobCoordinator
    let meshNotificationRouter: RoomMeshNotificationRouter
    let professionalEnvironmentFactory: ProfessionalEnvironmentFactory
    let privacyPolicyURL: URL?
    @Published private(set) var bootstrapMessage: String?

    private let cameraPermissionProvider: any RoomCameraPermissionProviding
    private let locationProvider: any RoomLocationProviding
    private let scratchWorkspaceFactory: RoomCaptureScratchWorkspaceFactory
    private let captureDriverFactory: any RoomCaptureDriverFactory
    private let savePolicy: any RoomCaptureSavePolicy
    private let attemptGenerator: any RoomCaptureAttemptIDGenerating
    private let captureCoordinatorLease = RoomCaptureCoordinatorLease()

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        professionalEnvironmentFactory: ProfessionalEnvironmentFactory? = nil
    ) {
#if DEBUG
        self.professionalEnvironmentFactory = professionalEnvironmentFactory
            ?? PhysicalProfessionalEvidenceHarness.factoryForCurrentBuild(
                arguments: arguments
            )
#else
        self.professionalEnvironmentFactory = professionalEnvironmentFactory
            ?? .defaultOff()
#endif
        let rootURL = RoomProjectRootResolver.resolve(
            arguments: arguments,
            fileManager: .default
        )
        let generator: any RoomProjectIDGenerating
        if arguments.contains("--use-mock-fixture") {
            generator = DeterministicRoomProjectIDGenerator(
                projectIDs: ["ui-project-001", "ui-project-002", "ui-project-003"],
                revisionIDs: ["revision-001", "revision-002", "revision-003", "revision-004"]
            )
        } else {
            generator = UUIDRoomProjectIDGenerator()
        }

        let store = LocalRoomProjectStore(
            rootURL: rootURL,
            idGenerator: generator
        )
        let localExtensionRoots = RoomRedesignLocalRootResolver.resolve(
            arguments: arguments,
            projectRootURL: rootURL,
            fileManager: .default
        )
        let redesignStore = LocalRoomRedesignStore(rootURL: localExtensionRoots.redesign)
        let propertyStore = LocalRoomPropertyStore(rootURL: localExtensionRoots.properties)
        let indexBootstrap = RoomProjectIndexBootstrap.makeContainer()

        let usesIsolatedUIEnvironment = arguments.contains("--ui-testing")
        let jobRecordStore = RoomMeshColoringJobRecordStore(
            fileURL: RoomMeshJobRecordRootResolver.resolve(
                arguments: arguments, fileManager: .default
            )
        )
        let notificationRouter = RoomMeshNotificationRouter()
        meshNotificationRouter = notificationRouter
        UNUserNotificationCenter.current().delegate = notificationRouter
        meshColoringCoordinator = RoomMeshColoringJobCoordinator(
            background: usesIsolatedUIEnvironment
                ? ForegroundOnlyRoomMeshBackgroundTaskAdapter()
                : AppleRoomMeshBackgroundTaskAdapter(),
            notifications: usesIsolatedUIEnvironment
                ? NoopRoomMeshColoringNotificationAdapter()
                : AppleRoomMeshColoringNotificationAdapter(),
            recordStore: jobRecordStore,
            isAppActive: { UIApplication.shared.applicationState == .active }
        )
        meshColoringCoordinator.reconcileStoredState {
            RoomMeshBundleLoader.hasValidPhotorealCache(forProject: $0)
        }

        let usesSimulatedCapture = arguments.contains("--use-simulated-capture")
        let scratchRootURL = RoomCaptureScratchRootResolver.resolve(
            arguments: arguments,
            fileManager: .default
        )
        scratchWorkspaceFactory = RoomCaptureScratchWorkspaceFactory(
            rootURL: scratchRootURL
        )
        let scratchRecoveryMessage: String?
        do {
            try scratchWorkspaceFactory.recoverOwnedOrphans()
            scratchRecoveryMessage = nil
        } catch {
            scratchRecoveryMessage = "Capture scratch recovery needs attention. A prior attempt was not removed."
        }

        if usesSimulatedCapture {
            // UI-test mode is deliberately self-contained: no camera prompt,
            // AR session, RoomPlan session, or device capability probe starts.
            capabilityProvider = FixtureDeviceCapabilityProvider(
                roomCaptureSupported: true,
                sceneMeshSupported: false
            )
            cameraPermissionProvider = StaticCameraPermissionProvider(
                permission: arguments.contains("--simulated-camera-denied")
                    ? .denied
                    : .authorized
            )
            locationProvider = StaticLocationProvider(
                result: arguments.contains("--simulated-gps-denied")
                    ? .denied
                    : .authorized(
                        RoomGPSLocation(
                            latitude: 40.7128,
                            longitude: -74.0060,
                            horizontalAccuracyMeters: 12,
                            capturedAt: Date(timeIntervalSince1970: 1_704_067_200)
                        )
                    )
            )
            captureDriverFactory = SimulatedRoomCaptureDriverFactory(
                scenario: SimulatedRoomCaptureScenario(
                    processingFails: arguments.contains("--simulated-processing-failure"),
                    processingFailuresBeforeSuccess: arguments.contains("--simulated-processing-fail-once") ? 1 : 0,
                    referencePhotoFails: arguments.contains("--simulated-photo-failure"),
                    suspendsProcessingUntilCancelled: arguments.contains("--simulated-processing-suspend"),
                    quality: Self.simulatedQualityScenario(arguments: arguments)
                )
            )
            if arguments.contains("--simulated-save-failure") {
                savePolicy = FailingRoomCaptureSavePolicy()
            } else {
                savePolicy = AcceptingRoomCaptureSavePolicy()
            }
            attemptGenerator = DeterministicRoomCaptureAttemptIDGenerator(
                values: ["simulated-attempt-001", "simulated-attempt-002"]
            )
        } else {
            capabilityProvider = SystemDeviceCapabilityProvider()
            // Production dependencies remain inert until the user explicitly
            // chooses Prepare or Request GPS. The driver owns exactly one
            // RoomCaptureView-derived ARSession/RoomCaptureSession pair per
            // leased attempt.
            cameraPermissionProvider = AppleCameraPermissionProvider()
            locationProvider = AppleLocationProvider()
            captureDriverFactory = AppleRoomCaptureDriverFactory()
            savePolicy = AcceptingRoomCaptureSavePolicy()
            attemptGenerator = UUIDRoomCaptureAttemptIDGenerator()
        }

        // V1-A keeps production master rescans hard-unavailable. The only
        // alternate path is an explicit UI-test/deterministic-fixture launch
        // argument; neither provider creates camera or AR work.
        if arguments.contains("--use-deterministic-rescan-fixture") {
            rescanProvider = DeterministicFixtureRoomRescanProvider()
        } else {
            rescanProvider = UnavailableRoomRescanProvider()
        }

        libraryController = RoomLibraryController(
            store: store,
            modelContainer: indexBootstrap.container,
            redesignStore: redesignStore,
            propertyStore: propertyStore
        )
        // Hero snapshots piggyback on the colored-mesh viewer's load, the one
        // moment the colored result is already resident — the profile never
        // loads a mesh just to render its hero image.
        let heroLibraryController = libraryController
        let heroPublishGate = HeroPublishGate()
        meshColoringCoordinator.onColoredResult = { projectID, result in
            // One hero render at a time: a new room's result cancels and
            // supersedes any straggler still holding the previous room's
            // mesh, so peak memory never stacks two rooms.
            heroPublishGate.task?.cancel()
            heroPublishGate.task = Task(priority: .utility) {
                guard !Task.isCancelled else { return }
                _ = await RoomMeshHeroPipeline.publishHero(
                    from: result, projectID: projectID, controller: heroLibraryController
                )
            }
        }
        let exportWorkspaceFactory = RoomExportWorkspaceFactory(
            rootURL: RoomExportScratchRootResolver.resolve(
                arguments: arguments,
                fileManager: .default
            )
        )
        let exportRecoveryMessage: String?
        do {
            let recovery = try exportWorkspaceFactory.recoverOwnedOrphans()
            if recovery.preservedUnownedOrUnsafeEntryCount > 0 {
                exportRecoveryMessage = "Export scratch recovery preserved unowned or unsafe entries for manual review."
            } else {
                exportRecoveryMessage = nil
            }
        } catch {
            exportRecoveryMessage = "Export scratch recovery needs attention. A prior handoff workspace was not removed."
        }
        exportCoordinator = RoomExportCoordinator(
            provider: RoomExportService(
                controller: libraryController,
                workspaceFactory: exportWorkspaceFactory,
                derivedProvider: UIKitRoomExportDerivedProvider()
            ),
            cleaner: exportWorkspaceFactory
        )
        let aiRedesignRoots = RoomAIRedesignRootResolver.resolve(
            arguments: arguments,
            projectRootURL: rootURL,
            fileManager: .default
        )
        aiRedesignModelFactory = RoomAIRedesignModelFactory(
            controller: libraryController,
            workspaceFactory: exportWorkspaceFactory,
            projectRootURL: rootURL,
            conceptRootURL: aiRedesignRoots.concepts,
            conceptImportScratchRootURL: aiRedesignRoots.importScratch
        )
        // This attaches only already-created local project access. It does not
        // construct a hosted client, authenticate, or attempt synchronization;
        // `ProfessionalEnvironmentFactory.defaultOff()` stays fully inert.
        self.professionalEnvironmentFactory.attachLocalProjectAccess(
            .init(
                libraryController: libraryController,
                aiRedesignModelFactory: aiRedesignModelFactory,
                professionalSyncJournalRoot: localExtensionRoots.redesign
                    .deletingLastPathComponent()
                    .appendingPathComponent("ProfessionalSyncJournal", isDirectory: true),
                publicationOperationJournalRoot: localExtensionRoots.redesign
                    .deletingLastPathComponent()
                    .appendingPathComponent("PublicationOperationJournal", isDirectory: true)
            )
        )
        let usesFakeCloudBackup = arguments.contains("--use-fake-cloud-backup")
        privacyPolicyURL = PrivacyPolicyURLResolver.resolve(
            rawValue: Bundle.main.object(
                forInfoDictionaryKey: "RoomScanStudioPrivacyPolicyURL"
            ) as? String
        )
        let cloudContainer = CloudBackupContainerArgument.resolve(
            arguments: arguments,
            buildContainerIdentifier: Bundle.main.object(
                forInfoDictionaryKey: "RoomScanStudioCloudBackupContainerIdentifier"
            ) as? String
        )
        let explicitCloudEnabled: Bool? = usesFakeCloudBackup || arguments.contains("--cloud-backup-enabled")
            ? true
            : (arguments.contains("--cloud-backup-disabled") ? false : nil)
        let cloudPreferences = RoomCloudBackupPreferences(
            isEnabled: explicitCloudEnabled,
            containerIdentifier: cloudContainer,
            // Isolated UI runs must not inherit or persist a prior device
            // consent value. Production uses the local UserDefaults default.
            defaults: arguments.contains("--ui-testing") ? nil : .standard
        )
        let cloudWorkspaceFactory = RoomCloudBackupWorkspaceFactory(
            rootURL: RoomCloudBackupScratchRootResolver.resolve(
                arguments: arguments,
                fileManager: .default
            )
        )
        let cloudRecoveryMessage: String?
        do {
            let recovery = try cloudWorkspaceFactory.recoverOwnedOrphans()
            cloudRecoveryMessage = recovery.preservedUnownedOrUnsafeEntryCount > 0
                ? "Cloud backup scratch recovery preserved unowned or unsafe entries for manual review."
                : nil
        } catch {
            cloudRecoveryMessage = "Cloud backup scratch recovery needs attention. No CloudKit call was made."
        }
        let cloudTransport: any RoomCloudBackupTransport = usesFakeCloudBackup
            ? DeterministicCloudBackupTransport(
                accountStatus: arguments.contains("--fake-cloud-account-unavailable")
                    ? .noAccount
                    : .available
            )
            : AppleCloudBackupTransport()
        cloudBackupCoordinator = RoomCloudBackupCoordinator(
            provider: RoomCloudBackupService(
                controller: libraryController,
                workspaceFactory: cloudWorkspaceFactory,
                transport: cloudTransport
            ),
            preferences: cloudPreferences
        )
        let bootstrapMessages = [
            indexBootstrap.message,
            scratchRecoveryMessage,
            exportRecoveryMessage,
            cloudRecoveryMessage,
        ]
            .compactMap { $0 }
        bootstrapMessage = bootstrapMessages.isEmpty
            ? nil
            : bootstrapMessages.joined(separator: " ")
        // Run once, after all current roots are resolved. A kept token launch
        // deliberately leaves every sibling alone.
        IsolatedTestRoots.sweepStaleRoots(arguments: arguments, fileManager: .default)
    }

    func handleProfessionalLifecycle(_ event: ProfessionalLifecycleEvent) {
        professionalEnvironmentFactory.handleLifecycle(event)
    }

    private static func simulatedQualityScenario(
        arguments: [String]
    ) -> SimulatedRoomQualityScenario {
        guard let index = arguments.firstIndex(of: "--simulated-quality"),
              arguments.indices.contains(index + 1),
              let scenario = SimulatedRoomQualityScenario(rawValue: arguments[index + 1])
        else { return .good }
        return scenario
    }

    /// A render pass may ask for the capture route more than once. The same
    /// coordinator retains the app-owned attempt/driver lease until a terminal
    /// state is reached after cleanup.
    func acquireCaptureCoordinator() -> RoomCaptureCoordinator {
        captureCoordinatorLease.acquire { [unowned self] in
            RoomCaptureCoordinator(
                controller: libraryController,
                cameraPermissionProvider: cameraPermissionProvider,
                locationProvider: locationProvider,
                workspaceFactory: scratchWorkspaceFactory,
                driver: captureDriverFactory.makeDriver(),
                savePolicy: savePolicy,
                attemptGenerator: attemptGenerator
            )
        }
    }

    func releaseCaptureCoordinator(_ coordinator: RoomCaptureCoordinator) {
        captureCoordinatorLease.release(coordinator)
    }
}

enum CloudBackupContainerArgument {
    static let deterministicFakeContainerIdentifier = "iCloud.org.roomscanstudio.ui-test"

    static func resolve(
        arguments: [String],
        buildContainerIdentifier: String?
    ) -> String {
        let prefix = "--cloud-container="
        if arguments.contains("--ui-testing"),
           let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
            if let resolved = normalized(String(argument.dropFirst(prefix.count))) {
                return resolved
            }
        }
        if let resolved = normalized(buildContainerIdentifier) {
            return resolved
        }
        if arguments.contains("--use-fake-cloud-backup") {
            return deterministicFakeContainerIdentifier
        }
        return ""
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              !trimmed.contains("${"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r")
        else {
            return nil
        }
        return trimmed
    }
}

/// Resolves an operator-owned Privacy Policy URL without manufacturing a
/// release value. A blank or unresolved build setting remains unconfigured.
enum PrivacyPolicyURLResolver {
    static func resolve(rawValue: String?) -> URL? {
        guard let rawValue,
              !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains("$("),
              !rawValue.contains("${"),
              !rawValue.contains("#"),
              let percentDecoded = rawValue.removingPercentEncoding,
              rawValue.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              percentDecoded.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url
        else {
            return nil
        }
        return url
    }
}

/// A single-scene V1 app still needs a durable in-memory lease: SwiftUI route
/// rendering can invoke acquisition repeatedly before a navigation transition
/// completes. Release is deliberately terminal-only.
@MainActor
final class RoomCaptureCoordinatorLease {
    private var coordinator: RoomCaptureCoordinator?

    func acquire(_ makeCoordinator: () -> RoomCaptureCoordinator) -> RoomCaptureCoordinator {
        if let coordinator {
            return coordinator
        }
        let created = makeCoordinator()
        coordinator = created
        return created
    }

    func release(_ candidate: RoomCaptureCoordinator) {
        guard coordinator === candidate, candidate.isTerminal else {
            return
        }
        coordinator = nil
    }
}

private struct RoomProjectIndexBootstrap {
    let container: ModelContainer?
    let message: String?

    static func makeContainer() -> RoomProjectIndexBootstrap {
        do {
            return RoomProjectIndexBootstrap(
                container: try RoomProjectIndexFactory.makeContainer(),
                message: nil
            )
        } catch {
            do {
                return RoomProjectIndexBootstrap(
                    container: try RoomProjectIndexFactory.makeContainer(
                        isStoredInMemoryOnly: true
                    ),
                    message: "Local search index is temporarily in memory. Room packages remain available."
                )
            } catch {
                return RoomProjectIndexBootstrap(
                    container: nil,
                    message: "Local search index could not start. Room packages remain available."
                )
            }
        }
    }
}

enum RoomProjectRootResolver {
    static func resolve(
        arguments: [String],
        fileManager: FileManager
    ) -> URL {
        // --isolated-root-token and --keep-isolated-root are gated on the
        // --ui-testing / --reset-local-store pair by the shared helper.
        if let testRoot = IsolatedTestRoots.resolve(
            .projects, arguments: arguments, fileManager: fileManager
        ) {
            return testRoot
        }

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RoomScanStudio", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }

    static func removeIsolatedTestRootIfSafe(
        _ testRoot: URL,
        temporaryRoot: URL,
        expectedName: String,
        fileManager: FileManager
    ) {
        let canonicalTemporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = canonicalTemporaryRoot.pathComponents
        let targetComponents = testRoot.standardizedFileURL.pathComponents
        let isContained = targetComponents.count == rootComponents.count + 1
            && zip(rootComponents, targetComponents).allSatisfy { pair in
                pair.0 == pair.1
            }
            && testRoot.lastPathComponent == expectedName
            && testRoot.resolvingSymlinksInPath().standardizedFileURL == testRoot.standardizedFileURL
        guard isContained else {
            return
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: testRoot.path)) == nil else {
            return
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: testRoot.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return
        }
        do {
            try fileManager.removeItem(at: testRoot)
        } catch {
            return
        }
    }
}

enum RoomRedesignLocalRootResolver {
    struct Roots {
        let redesign: URL
        let properties: URL
    }

    static func resolve(
        arguments: [String],
        projectRootURL: URL,
        fileManager: FileManager
    ) -> Roots {
        if let redesign = IsolatedTestRoots.resolve(.redesignState, arguments: arguments, fileManager: fileManager),
           let properties = IsolatedTestRoots.resolve(.properties, arguments: arguments, fileManager: fileManager) {
            return Roots(redesign: redesign, properties: properties)
        }
        let appRoot = projectRootURL.deletingLastPathComponent()
        return Roots(
            redesign: appRoot.appendingPathComponent("RedesignState", isDirectory: true),
            properties: appRoot.appendingPathComponent("Properties", isDirectory: true)
        )
    }
}

enum RoomCaptureScratchRootResolver {
    static func resolve(
        arguments: [String],
        fileManager: FileManager
    ) -> URL {
        if let scratchRoot = IsolatedTestRoots.resolve(
            .captureScratch, arguments: arguments, fileManager: fileManager
        ) {
            return scratchRoot
        }

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RoomScanStudio", isDirectory: true)
            .appendingPathComponent("CaptureScratch", isDirectory: true)
    }
}

/// Single-slot holder so hero publication is serialized without capturing a
/// partially-initialized AppEnvironment in its own init.
@MainActor
final class HeroPublishGate {
    var task: Task<Void, Never>?
}
