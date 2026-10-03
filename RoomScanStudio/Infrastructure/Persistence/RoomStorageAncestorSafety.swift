import Foundation

/// Shared ancestor walk for marker-owned app storage roots.
///
/// On a physical device the container is reported as `/var/mobile/...`, and
/// `resolvingSymlinksInPath()` strips `/private` back to that form, so every
/// production root passes through the root-owned `/var -> private/var` link.
/// Only a root-owned link directly under `/` is trusted. The app runs as a
/// non-root user and cannot create one, so any link it or another app-reachable
/// writer could plant still fails closed.
enum RoomStorageAncestorSafety {
    /// `FileManager.fileExists` follows links, so each extant component is
    /// checked with `destinationOfSymbolicLink` first. A missing component ends
    /// the walk; no deeper component can exist without it.
    static func existingAncestorsAreSafe(of url: URL, fileManager: FileManager) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (depth, component) in standardized.pathComponents.dropFirst().enumerated() {
            current.appendPathComponent(component, isDirectory: false)
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil,
               !(depth == 0 && isRootOwned(current, fileManager: fileManager)) {
                return false
            }
            guard fileManager.fileExists(atPath: current.path) else { return true }
        }
        return true
    }

    /// `attributesOfItem` describes the link itself, not its destination.
    private static func isRootOwned(_ link: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: link.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let owner = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        return owner.intValue == 0
    }
}
