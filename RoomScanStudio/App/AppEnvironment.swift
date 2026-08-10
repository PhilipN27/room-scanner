import Combine
import Foundation
import SwiftData
import RoomScanCore

@MainActor
final class AppEnvironment: ObservableObject {
    let capabilityProvider: any DeviceCapabilityProviding
    let libraryController: RoomLibraryController
    let rescanProvider: any RoomRescanProviding
    let exportCoordinator: RoomExportCoordinator
    let cloudBackupCoordinator: RoomCloudBackupCoordinator
    let privacyPolicyURL: URL?
    @Published private(set) var bootstrapMessage: String?

    private let cameraPermissionProvider: any RoomCameraPermissionProviding
    private let locationProvider: any RoomLocationProviding
    private let scratchWorkspaceFactory: RoomCaptureScratchWorkspaceFactory
    private let captureDriverFactory: any RoomCaptureDriverFactory
    private let savePolicy: any RoomCaptureSavePolicy
    private let attemptGenerator: any RoomCaptureAttemptIDGenerating
    private let captureCoordinatorLease = RoomCaptureCoordinatorLease()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
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
        let indexBootstrap = RoomProjectIndexBootstrap.makeContainer()

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
                    suspendsProcessingUntilCancelled: arguments.contains("--simulated-processing-suspend")
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
            // injected ARSession/RoomCaptureSession pair per leased attempt.
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
            modelContainer: indexBootstrap.container
        )
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
    private static let isolatedTestingDirectoryName = "RoomScanStudio-UI-Testing-Projects"

    static func resolve(
        arguments: [String],
        fileManager: FileManager
    ) -> URL {
        let isIsolatedUIRun = arguments.contains("--ui-testing")
            && arguments.contains("--reset-local-store")
        if isIsolatedUIRun {
            let temporaryRoot = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let testRoot = temporaryRoot.appendingPathComponent(
                isolatedTestingDirectoryName,
                isDirectory: true
            )
            removeIsolatedTestRootIfSafe(testRoot, temporaryRoot: temporaryRoot, fileManager: fileManager)
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

    private static func removeIsolatedTestRootIfSafe(
        _ testRoot: URL,
        temporaryRoot: URL,
        fileManager: FileManager
    ) {
        let rootComponents = temporaryRoot.standardizedFileURL.pathComponents
        let targetComponents = testRoot.standardizedFileURL.pathComponents
        let isContained = targetComponents.count == rootComponents.count + 1
            && zip(rootComponents, targetComponents).allSatisfy { pair in
                pair.0 == pair.1
            }
            && testRoot.lastPathComponent == isolatedTestingDirectoryName
        guard isContained else {
            return
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: testRoot.path)) == nil else {
            return
        }
        guard fileManager.fileExists(atPath: testRoot.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: testRoot)
        } catch {
            return
        }
    }
}

enum RoomCaptureScratchRootResolver {
    private static let isolatedTestingDirectoryName = "RoomScanStudio-UI-Testing-CaptureScratch"

    static func resolve(
        arguments: [String],
        fileManager: FileManager
    ) -> URL {
        let isIsolatedUIRun = arguments.contains("--ui-testing")
            && arguments.contains("--reset-local-store")
        if isIsolatedUIRun {
            let temporaryRoot = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let scratchRoot = temporaryRoot.appendingPathComponent(
                isolatedTestingDirectoryName,
                isDirectory: true
            )
            removeIsolatedScratchRootIfSafe(
                scratchRoot,
                temporaryRoot: temporaryRoot,
                fileManager: fileManager
            )
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

    private static func removeIsolatedScratchRootIfSafe(
        _ scratchRoot: URL,
        temporaryRoot: URL,
        fileManager: FileManager
    ) {
        let rootComponents = temporaryRoot.standardizedFileURL.pathComponents
        let targetComponents = scratchRoot.standardizedFileURL.pathComponents
        let isContained = targetComponents.count == rootComponents.count + 1
            && zip(rootComponents, targetComponents).allSatisfy { pair in
                pair.0 == pair.1
            }
            && scratchRoot.lastPathComponent == isolatedTestingDirectoryName
        guard isContained,
              fileManager.fileExists(atPath: scratchRoot.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: scratchRoot.path)) == nil
        else {
            return
        }
        do {
            try fileManager.removeItem(at: scratchRoot)
        } catch {
            return
        }
    }
}
