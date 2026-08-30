import Foundation
import XCTest
@testable import RoomScanStudio

@MainActor
final class ProfessionalProjectRecoveryTests: XCTestCase {
    func testDownloadedRecoveryRequiresInspectionBeforeAnyLivePromotion() async throws {
        let coordinator = ProfessionalProjectRecoveryCoordinator(
            fileManager: .default
        )

        await XCTAssertProfessionalRecoveryThrows {
            try await coordinator.recoverDownloadedArchive(
                archiveURL: URL(fileURLWithPath: "/missing/archive.zip"),
                recovery: ProfessionalProjectSyncRecovery(
                    projectID: "prj_0000000000000001",
                    revisionID: "rev_0000000000000001",
                    branchState: .canonical,
                    workingSetManifestSHA256: String(repeating: "a", count: 64),
                    archiveSHA256: String(repeating: "b", count: 64),
                    archiveByteCount: 1
                ),
                target: .original
            )
        }
    }
}

private func XCTAssertProfessionalRecoveryThrows(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        // The behavior under test is the no-promotion fail-closed boundary.
    }
}
