import Foundation
import RoomScanCore

struct MockRoomFixture: Sendable {
    let manifest: RoomProjectManifest
    let draft: RoomDraft
    let thumbnailAsset: RoomAssetInput
    let revisionAssets: [RoomAssetInput]

    var assets: [RoomAssetInput] {
        [thumbnailAsset] + revisionAssets
    }
}

enum MockRoomFixtureLoaderError: Error {
    case missingResource(String)
    case inconsistentFixture
}

enum MockRoomFixtureLoader {
    static func load(bundle: Bundle = .main) throws -> MockRoomFixture {
        let manifest = try decode(RoomProjectManifest.self, named: "manifest", bundle: bundle)
        let metadata = try decode(RoomMetadata.self, named: "metadata", bundle: bundle)
        let revision = try decode(RoomRevisionManifest.self, named: "revision", bundle: bundle)
        let semantic = try decode(RoomSemanticSnapshot.self, named: "semantic-model", bundle: bundle)
        let annotations = try decode(RoomAnnotationsDocument.self, named: "annotations", bundle: bundle)
        let measurements = try decode(RoomMeasurementsDocument.self, named: "measurements", bundle: bundle)
        let photos = try decode(RoomPhotosDocument.self, named: "photos", bundle: bundle)
        let thumbnailDestination = try RoomRelativePath("thumbnails/thumbnail.png")
        let fixturePhotoDestination = try RoomRelativePath("photos/reference-001.png")
        guard let thumbnailURL = bundle.url(forResource: "thumbnail", withExtension: "png") else {
            throw MockRoomFixtureLoaderError.missingResource("thumbnail.png")
        }

        guard
            manifest.projectID == "mock-room-v1",
            manifest.headRevisionID == "revision-001",
            manifest.revisionIDs == ["revision-001"],
            metadata.projectID == manifest.projectID,
            revision.projectID == manifest.projectID,
            revision.revisionID == manifest.headRevisionID,
            semantic.projectID == manifest.projectID,
            semantic.revisionID == manifest.headRevisionID,
            annotations.projectID == manifest.projectID,
            annotations.revisionID == manifest.headRevisionID,
            measurements.projectID == manifest.projectID,
            measurements.revisionID == manifest.headRevisionID,
            photos.projectID == manifest.projectID,
            photos.revisionID == manifest.headRevisionID,
            metadata.thumbnailRelativePath == thumbnailDestination,
            photos.photos.count == 1,
            photos.photos.first?.assetRelativePath == fixturePhotoDestination,
            photos.photos.first?.cameraTransform?.isValid == true
        else {
            throw MockRoomFixtureLoaderError.inconsistentFixture
        }

        return MockRoomFixture(
            manifest: manifest,
            draft: RoomDraft(
                metadata: metadata,
                revision: RoomRevisionPayload(
                    semanticSnapshot: semantic,
                    annotations: annotations.annotations,
                    measurements: measurements.measurements,
                    photos: photos.photos
                )
            ),
            thumbnailAsset: RoomAssetInput(
                sourceURL: thumbnailURL,
                destination: thumbnailDestination,
                scope: .project
            ),
            // The bundled PNG is intentionally reused as a deterministic photo
            // source. It is copied to a revision-local path only on explicit
            // fixture Save; it is never a claim of a live camera capture.
            revisionAssets: [
                RoomAssetInput(
                    sourceURL: thumbnailURL,
                    destination: fixturePhotoDestination,
                    scope: .revision
                )
            ]
        )
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        named name: String,
        bundle: Bundle
    ) throws -> T {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MockRoomFixtureLoaderError.missingResource("\(name).json")
        }
        let data = try Data(contentsOf: url)
        return try RoomJSONCoding.makeDecoder().decode(T.self, from: data)
    }
}

struct MockRoomReviewPersistenceCoordinator {
    let store: LocalRoomProjectStore

    func resolve(
        fixture: MockRoomFixture,
        disposition: RoomDraftDecision
    ) async throws -> RoomProjectSummary? {
        try await store.saveDraft(
            fixture.draft,
            decision: disposition,
            assets: fixture.assets
        )
    }
}
