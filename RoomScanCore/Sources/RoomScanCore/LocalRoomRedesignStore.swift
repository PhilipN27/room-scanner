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
        try requireExistingStorePathComponentsNonSymlink(
            through: fileURL.deletingLastPathComponent()
        )
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

    /// Captures the exact canonical local companion payload bound to one
    /// immutable source revision. A missing companion is deliberately not an
    /// error so a professional working set can omit redesign state.
    public func snapshot(
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> RoomProfessionalRedesignSnapshot? {
        try sourceRevision.validate()
        let fileURL = try stateURL(for: sourceRevision)
        try requireExistingStorePathComponentsNonSymlink(
            through: fileURL.deletingLastPathComponent()
        )
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        try requireRegularNonSymlink(fileURL)
        let data = try Data(contentsOf: fileURL)
        return try RoomProfessionalRedesignSnapshot(
            sourceRevision: sourceRevision,
            canonicalDocumentData: data,
            documentSHA256: RoomSHA256.hexDigest(of: data)
        )
    }

    /// Restores a strict snapshot only when it remains bound to the requested
    /// source revision, or when the caller presents the one explicit mapping
    /// that authorizes a recovered-copy rebind. Existing local state is never
    /// overwritten: exact canonical bytes are idempotent and any difference
    /// fails closed.
    public func restoreSnapshot(
        _ snapshot: RoomProfessionalRedesignSnapshot,
        expectedSourceRevision: RoomRedesignSourceRevision,
        recoveredCopyMapping: RoomProfessionalRecoveredCopyMapping? = nil
    ) throws {
        try expectedSourceRevision.validate()
        let original = try snapshot.validatedDocument()
        let destinationSource = try RoomProfessionalRecoveryRebinding.targetSourceRevision(
            original: snapshot.sourceRevision,
            expected: expectedSourceRevision,
            mapping: recoveredCopyMapping
        )
        let destination: RoomLocalRedesignExtensionV2
        if destinationSource == snapshot.sourceRevision {
            destination = original
        } else {
            guard let recoveredCopyMapping else {
                throw RoomProfessionalRecoveryError.sourceRevisionMismatch(
                    "A different destination source revision requires an explicit recovered-copy mapping."
                )
            }
            destination = try RoomProfessionalRecoveryRebinding.rebind(
                redesign: original,
                targetSourceRevision: destinationSource,
                mapping: recoveredCopyMapping
            )
        }
        let destinationData = try RoomRedesignCanonicalJSON.encode(destination)
        guard case let .localRedesignExtensionV2(reopened) = try RoomRedesignContractValidator.validate(
            data: destinationData
        ), reopened == destination, reopened.sourceRevision == expectedSourceRevision else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Restored redesign companion did not remain canonical and bound to its destination source revision."
            )
        }

        let fileURL = try stateURL(for: expectedSourceRevision)
        try requireExistingStorePathComponentsNonSymlink(
            through: fileURL.deletingLastPathComponent()
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            try requireExactExistingSnapshot(
                at: fileURL,
                expectedData: destinationData,
                expectedSourceRevision: expectedSourceRevision
            )
            return
        }

        try prepareParent(of: fileURL)
        do {
            try destinationData.write(to: fileURL, options: .withoutOverwriting)
        } catch {
            // A competing local writer can only make this idempotent when it
            // wrote the exact same canonical, source-bound payload.
            guard fileManager.fileExists(atPath: fileURL.path) else { throw error }
            try requireExactExistingSnapshot(
                at: fileURL,
                expectedData: destinationData,
                expectedSourceRevision: expectedSourceRevision
            )
            return
        }
        try requireExactExistingSnapshot(
            at: fileURL,
            expectedData: destinationData,
            expectedSourceRevision: expectedSourceRevision
        )
    }

    public func remove(sourceRevision: RoomRedesignSourceRevision) throws {
        try sourceRevision.validate()
        let fileURL = try stateURL(for: sourceRevision)
        try requireExistingStorePathComponentsNonSymlink(
            through: fileURL.deletingLastPathComponent()
        )
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

    private func requireExactExistingSnapshot(
        at fileURL: URL,
        expectedData: Data,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) throws {
        try requireExistingStorePathComponentsNonSymlink(
            through: fileURL.deletingLastPathComponent()
        )
        try requireRegularNonSymlink(fileURL)
        let existingData = try Data(contentsOf: fileURL)
        guard case let .localRedesignExtensionV2(existing) = try RoomRedesignContractValidator.validate(
            data: existingData
        ), existing.sourceRevision == expectedSourceRevision,
              try RoomRedesignCanonicalJSON.encode(existing) == existingData,
              existingData == expectedData
        else {
            throw RoomProfessionalRecoveryError.existingStateConflict(
                "A different redesign companion already exists for this immutable source revision."
            )
        }
    }

    /// A strict leaf check is insufficient when the configured companion root
    /// or its project directory was replaced with a symlink. Walk only from
    /// the configured root (not system ancestors such as `/var`) through the
    /// selected project directory and reject every existing symbolic component
    /// before reading or accepting an idempotent destination.
    private func requireExistingStorePathComponentsNonSymlink(
        through target: URL
    ) throws {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count >= rootComponents.count,
              zip(rootComponents, targetComponents).allSatisfy({ $0 == $1 })
        else {
            throw RoomProjectStoreError.invalidPackage(
                "Redesign companion path escapes its configured store root."
            )
        }
        guard pathExists(rootURL) else { return }
        try requireDirectoryNonSymlink(rootURL)

        var current = rootURL
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            guard pathExists(current) else { return }
            try requireDirectoryNonSymlink(current)
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
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
