import Foundation

/// Companion state lives beside, never inside, immutable room packages. The
/// source binding determines the path and every save revalidates it.
public actor LocalRoomRedesignStore {
    private let rootURL: URL
    private let fileManager = FileManager.default

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func load(
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> RoomLocalRedesignExtensionV2? {
        try sourceRevision.validate()
        let fileURL = try stateURL(for: sourceRevision)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        try requireRegularNonSymlink(fileURL)
        let data = try Data(contentsOf: fileURL)
        guard case let .localRedesignExtensionV2(document) = try RoomRedesignContractValidator.validate(data: data),
              document.sourceRevision == sourceRevision
        else {
            throw RoomProjectStoreError.invalidPackage("Redesign companion state is bound to another immutable revision.")
        }
        return document
    }

    public func save(
        _ document: RoomLocalRedesignExtensionV2,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) throws {
        try expectedSourceRevision.validate()
        try document.validate()
        guard document.sourceRevision == expectedSourceRevision else {
            throw RoomProjectStoreError.invalidPackage("Redesign companion state cannot be rebound to another revision or coordinate-space epoch.")
        }
        let data = try RoomRedesignCanonicalJSON.encode(document)
        guard case let .localRedesignExtensionV2(decoded) = try RoomRedesignContractValidator.validate(data: data),
              decoded == document
        else {
            throw RoomProjectStoreError.invalidPackage("Redesign companion state failed canonical contract validation.")
        }
        let fileURL = try stateURL(for: expectedSourceRevision)
        try prepareParent(of: fileURL)
        try data.write(to: fileURL, options: .atomic)
        try requireRegularNonSymlink(fileURL)
    }

    public func remove(sourceRevision: RoomRedesignSourceRevision) throws {
        try sourceRevision.validate()
        let fileURL = try stateURL(for: sourceRevision)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try requireRegularNonSymlink(fileURL)
        try fileManager.removeItem(at: fileURL)
    }

    private func stateURL(for source: RoomRedesignSourceRevision) throws -> URL {
        guard RoomPathValidation.isSafeStableIdentifier(source.projectID),
              RoomPathValidation.isSafeStableIdentifier(source.revisionID)
        else {
            throw RoomProjectStoreError.invalidPackage("Unsafe redesign companion identifier.")
        }
        return rootURL
            .appendingPathComponent(source.projectID, isDirectory: true)
            .appendingPathComponent("\(source.revisionID).json")
    }

    private func prepareParent(of fileURL: URL) throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try requireDirectoryNonSymlink(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        let parent = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.path) {
            try requireDirectoryNonSymlink(parent)
        } else {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
        }
    }

    private func requireDirectoryNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RoomProjectStoreError.symbolicLinkDetected(url.lastPathComponent)
        }
    }

    private func requireRegularNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RoomProjectStoreError.symbolicLinkDetected(url.lastPathComponent)
        }
    }
}

/// Local property grouping is deliberately only a set of independent project
/// identifiers. There is no transform, topology, doorway, or alignment API.
public actor LocalRoomPropertyStore {
    private let rootURL: URL
    private let fileManager = FileManager.default

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func save(_ property: RoomPropertyContainerV1) throws {
        try property.validate()
        let existing = try list()
        for other in existing where other.propertyID != property.propertyID {
            let overlap = Set(other.roomProjectIDs).intersection(property.roomProjectIDs)
            guard overlap.isEmpty else {
                throw RoomProjectStoreError.invalidPackage(
                    "A room project can belong to only one lightweight property container."
                )
            }
        }
        try prepareRoot()
        let fileURL = try propertyURL(property.propertyID)
        let data = try RoomRedesignCanonicalJSON.encode(property)
        try data.write(to: fileURL, options: .atomic)
        try requireRegularNonSymlink(fileURL)
    }

    public func list() throws -> [RoomPropertyContainerV1] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        try requireDirectoryNonSymlink(rootURL)
        let files = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var properties: [RoomPropertyContainerV1] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard file.pathExtension == "json" else {
                throw RoomProjectStoreError.invalidPackage("Unexpected file in the property container store.")
            }
            try requireRegularNonSymlink(file)
            let data = try Data(contentsOf: file)
            let property: RoomPropertyContainerV1
            do {
                property = try RoomJSONCoding.makeDecoder().decode(RoomPropertyContainerV1.self, from: data)
                try property.validate()
            } catch let error as RoomRedesignContractValidationError {
                throw error
            } catch {
                throw RoomProjectStoreError.invalidPackage("Property container JSON is invalid.")
            }
            guard try RoomRedesignCanonicalJSON.encode(property) == data,
                  file.deletingPathExtension().lastPathComponent == property.propertyID
            else {
                throw RoomProjectStoreError.invalidPackage("Property container bytes are non-canonical or rebound.")
            }
            properties.append(property)
        }
        let memberships = properties.flatMap(\.roomProjectIDs)
        guard Set(memberships).count == memberships.count else {
            throw RoomProjectStoreError.invalidPackage("A room project appears in multiple property containers.")
        }
        return properties.sorted { lhs, rhs in
            if lhs.displayName == rhs.displayName { return lhs.propertyID < rhs.propertyID }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public func property(containing roomProjectID: String) throws -> RoomPropertyContainerV1? {
        guard RoomPathValidation.isSafeStableIdentifier(roomProjectID) else {
            throw RoomProjectStoreError.invalidPackage("Unsafe room project identifier.")
        }
        return try list().first { $0.roomProjectIDs.contains(roomProjectID) }
    }

    public func remove(propertyID: String) throws {
        let fileURL = try propertyURL(propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try requireRegularNonSymlink(fileURL)
        try fileManager.removeItem(at: fileURL)
    }

    private func propertyURL(_ propertyID: String) throws -> URL {
        guard RoomPathValidation.isSafeStableIdentifier(propertyID) else {
            throw RoomProjectStoreError.invalidPackage("Unsafe property identifier.")
        }
        return rootURL.appendingPathComponent("\(propertyID).json")
    }

    private func prepareRoot() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try requireDirectoryNonSymlink(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    private func requireDirectoryNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RoomProjectStoreError.symbolicLinkDetected(url.lastPathComponent)
        }
    }

    private func requireRegularNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RoomProjectStoreError.symbolicLinkDetected(url.lastPathComponent)
        }
    }
}
