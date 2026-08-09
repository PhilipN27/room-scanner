import Foundation

enum RoomAtomicFileWriterError: Error {
    case destinationAlreadyExists(String)
    case unsafeParent(String)
}

/// Creates a new file without exposing partially written bytes or replacing an
/// existing directory entry. The temporary file lives beside the destination,
/// so the final move stays on the same volume.
public enum RoomAtomicFileWriter {
    public static func writeNewFile(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard
            fileManager.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue,
            !isSymbolicLink(parentURL, fileManager: fileManager)
        else {
            throw RoomAtomicFileWriterError.unsafeParent(parentURL.path)
        }
        guard !entryExists(destinationURL, fileManager: fileManager) else {
            throw RoomAtomicFileWriterError.destinationAlreadyExists(destinationURL.path)
        }

        let temporaryURL = parentURL.appendingPathComponent(
            ".roomscan-new-file-\(UUID().uuidString.lowercased())"
        )
        var ownsTemporaryFile = false
        defer {
            if ownsTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try data.write(to: temporaryURL, options: [.withoutOverwriting])
            ownsTemporaryFile = true
        } catch {
            let cocoaError = error as NSError
            let collidedWithExistingEntry =
                cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == CocoaError.Code.fileWriteFileExists.rawValue
            if !collidedWithExistingEntry,
               entryExists(temporaryURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }

        // Recheck before the move for a clearer failure. moveItem remains the
        // authoritative no-overwrite boundary if another writer races here.
        guard !entryExists(destinationURL, fileManager: fileManager) else {
            throw RoomAtomicFileWriterError.destinationAlreadyExists(destinationURL.path)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        ownsTemporaryFile = false
    }

    private static func entryExists(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || isSymbolicLink(url, fileManager: fileManager)
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
