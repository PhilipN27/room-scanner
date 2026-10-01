import Foundation

/// Tokens never change production paths. PID fallback keeps unrelated test
/// processes from clearing one another's active roots.
enum IsolatedRootSuffix {
    static func isIsolatedRun(arguments: [String]) -> Bool {
        arguments.contains("--ui-testing") && arguments.contains("--reset-local-store")
    }

    static func token(arguments: [String]) -> String? {
        let prefix = "--isolated-root-token="
        guard isIsolatedRun(arguments: arguments),
              let argument = arguments.first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let value = String(argument.dropFirst(prefix.count))
        guard (1...64).contains(value.utf8.count),
              value.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 95 || $0 == 45
              })
        else { return nil }
        return value
    }

    static func resolve(arguments: [String]) -> String {
        token(arguments: arguments) ?? String(ProcessInfo.processInfo.processIdentifier)
    }

    static func keepsRoot(arguments: [String]) -> Bool {
        token(arguments: arguments) != nil && arguments.contains("--keep-isolated-root")
    }
}

/// Register new isolated siblings here so naming, keep/reset and stale cleanup
/// cannot drift. Resolving a path does not create it.
enum IsolatedTestRoots {
    enum Kind: String, CaseIterable {
        case projects = "Projects"
        case captureScratch = "CaptureScratch"
        case meshJob = "MeshJob"
        case redesignState = "RedesignState"
        case properties = "Properties"
        case conceptSets = "ConceptSets"
        case conceptImportScratch = "ConceptImportScratch"
        case exportScratch = "ExportScratch"
        case cloudBackupScratch = "CloudBackupScratch"
        case cloudBackupDeletionJournal = "CloudBackupDeletionJournal"
        case fakeCloudBackup = "FakeCloudBackup"

        var prefix: String {
            self == .meshJob ? "RoomScanStudio-UI-MeshJob-" : "RoomScanStudio-UI-Testing-\(rawValue)-"
        }
    }

    static func resolve(
        _ kind: Kind,
        arguments: [String],
        fileManager: FileManager,
        wipeOnReset: Bool = true
    ) -> URL? {
        guard IsolatedRootSuffix.isIsolatedRun(arguments: arguments) else { return nil }
        let temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let name = kind.prefix + IsolatedRootSuffix.resolve(arguments: arguments)
        let root = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        if wipeOnReset && !IsolatedRootSuffix.keepsRoot(arguments: arguments) {
            RoomProjectRootResolver.removeIsolatedTestRootIfSafe(
                root, temporaryRoot: temporaryRoot, expectedName: name, fileManager: fileManager
            )
        }
        return root
    }

    static func sweepStaleRoots(
        arguments: [String],
        fileManager: FileManager,
        now: Date = Date()
    ) {
        guard IsolatedRootSuffix.isIsolatedRun(arguments: arguments),
              !IsolatedRootSuffix.keepsRoot(arguments: arguments)
        else { return }
        let temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let currentNames = Set(Kind.allCases.map {
            $0.prefix + IsolatedRootSuffix.resolve(arguments: arguments)
        })
        guard let siblings = try? fileManager.contentsOfDirectory(
            at: temporaryRoot, includingPropertiesForKeys: nil
        ) else { return }
        for sibling in siblings {
            let name = sibling.lastPathComponent
            guard !currentNames.contains(name),
                  Kind.allCases.contains(where: { name.hasPrefix($0.prefix) }),
                  let attributes = try? fileManager.attributesOfItem(atPath: sibling.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 60 * 60
            else { continue }
            RoomProjectRootResolver.removeIsolatedTestRootIfSafe(
                sibling, temporaryRoot: temporaryRoot, expectedName: name, fileManager: fileManager
            )
        }
    }
}

enum RoomMeshJobRecordRootResolver {
    static func resolve(arguments: [String], fileManager: FileManager) -> URL {
        if let root = IsolatedTestRoots.resolve(.meshJob, arguments: arguments, fileManager: fileManager) {
            return root.appendingPathComponent("active-job.json")
        }
        return RoomMeshColoringJobRecordStore.applicationSupport(fileManager: fileManager).fileURL
    }
}
