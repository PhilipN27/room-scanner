#!/usr/bin/env python3
"""Host-only structural verifier for RoomScanStudio through Phase 7."""

from __future__ import annotations

import json
import plistlib
import re
import sys
import xml.etree.ElementTree as element_tree
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "RoomScanStudio.xcodeproj" / "project.pbxproj"
SCHEME = ROOT / "RoomScanStudio.xcodeproj" / "xcshareddata" / "xcschemes" / "RoomScanStudio.xcscheme"
INFO_PLIST = ROOT / "RoomScanStudio" / "Resources" / "Info.plist"
PRIVACY_PLIST = ROOT / "RoomScanStudio" / "Resources" / "PrivacyInfo.xcprivacy"
PACKAGE = ROOT / "Package.swift"
FIXTURE_ROOT = ROOT / "RoomScanStudio" / "Fixtures" / "MockRoom-v1"
RESCAN_FIXTURE = ROOT / "RoomScanStudio" / "Fixtures" / "RescanFixture-v1" / "rescan-fixture-v1.json"
APP_ICON_DIRECTORY = ROOT / "RoomScanStudio" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
APP_ICON = APP_ICON_DIRECTORY / "AppIcon-1024.png"
APP_THEME = ROOT / "RoomScanStudio" / "App" / "AppTheme.swift"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
SIMULATOR_SELECTOR = ROOT / "Scripts" / "select_simulators.py"


def object_body(pbx: str, identifier: str) -> str | None:
    """Return a top-level PBX object body without truncating nested dictionaries."""
    pattern = rf"(?m)^\s*{re.escape(identifier)}\s*/\*[^\r\n]*?\*/\s*=\s*\{{"
    match = re.search(pattern, pbx)
    if match is None:
        return None

    depth = 1
    for index in range(match.end(), len(pbx)):
        character = pbx[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return pbx[match.end():index]
    return None


def expect(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def read_json(path: Path, errors: list[str]) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"invalid JSON: {path.relative_to(ROOT)} ({error})")
        return {}


def read_plist(path: Path, errors: list[str]) -> dict:
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        errors.append(f"invalid plist: {path.relative_to(ROOT)} ({error})")
        return {}


def verify_required_files(errors: list[str]) -> None:
    required = [
        PROJECT,
        SCHEME,
        INFO_PLIST,
        PRIVACY_PLIST,
        PACKAGE,
        ROOT / "Docs" / "feasibility.md",
        ROOT / "Docs" / "architecture.md",
        ROOT / "Docs" / "export-format.md",
        ROOT / "Docs" / "icloud-setup.md",
        ROOT / "Docs" / "setup.md",
        ROOT / "Docs" / "real-device-test-plan.md",
        ROOT / "Docs" / "privacy.md",
        ROOT / "Docs" / "storage-performance.md",
        ROOT / "Docs" / "known-limitations.md",
        ROOT / "Docs" / "release-checklist.md",
        ROOT / "Docs" / "dependencies.md",
        ROOT / "Docs" / "verification-log.md",
        ROOT / "README.md",
        ROOT / "CONTRIBUTING.md",
        ROOT / "SECURITY.md",
        WORKFLOW,
        SIMULATOR_SELECTOR,
        APP_THEME,
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomScanCore.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomAtomicFileWriter.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomModels.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomCaptureReducer.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomSHA256.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomPlanSemanticMapper.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomRescan.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomViewerEditor.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomExport.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomCRC32.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomDeterministicZIP.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomHeadExportBuilder.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomFloorPlanProjection.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomBackup.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomProjectBackupArchive.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomProjectStateTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreTransactionTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStorePhase1BTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "CaptureReducerTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreCaptureTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomPlanSemanticMapperTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomRescanTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomViewerEditorTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreEditTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomExportTests.swift",
        ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomBackupTests.swift",
        ROOT / "RoomScanStudio" / "App" / "RoomScanStudioApp.swift",
        ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        ROOT / "RoomScanStudio" / "Features" / "Home" / "DeviceCapability.swift",
        ROOT / "RoomScanStudio" / "Features" / "Home" / "HomeView.swift",
        ROOT / "RoomScanStudio" / "Features" / "Home" / "ExistingRoomsView.swift",
        ROOT / "RoomScanStudio" / "Features" / "Home" / "NewRoomScanCapabilityView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomMetadataEditorView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RevisionHistoryView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "MockRoomReviewView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureCoordinator.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureFlowView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomRescanFlowView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerRealityView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomEditor" / "RoomEditorView.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomProjectIndex.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "FileStorage" / "MockRoomFixtureLoader.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "FileStorage" / "RescanFixtureLoader.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "RoomCaptureDependencies.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "SimulatedRoomCaptureDriver.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "AppleCaptureDependencies.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "AppleRoomCaptureDriver.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "RoomExportCoordinator.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "RoomExportService.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "UIKitRoomExportDerivedProvider.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupModels.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupCoordinator.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupService.swift",
        ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "AppleCloudBackupTransport.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomExportView.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomCloudBackupViews.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomScanStudioTests.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomCaptureCoordinatorTests.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "AppleCaptureDependencyTests.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomViewerEditorAppTests.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomExportAppTests.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomCloudBackupAppTests.swift",
        ROOT / "RoomScanStudio" / "RoomScanStudioUITests" / "RoomScanStudioUITests.swift",
        APP_ICON_DIRECTORY / "Contents.json",
        APP_ICON,
        FIXTURE_ROOT / "manifest.json",
        FIXTURE_ROOT / "metadata.json",
        FIXTURE_ROOT / "revisions" / "revision-001" / "revision.json",
        FIXTURE_ROOT / "revisions" / "revision-001" / "semantic-model.json",
        FIXTURE_ROOT / "revisions" / "revision-001" / "annotations.json",
        FIXTURE_ROOT / "revisions" / "revision-001" / "measurements.json",
        FIXTURE_ROOT / "revisions" / "revision-001" / "photos.json",
        FIXTURE_ROOT / "assets" / "thumbnail.png",
        RESCAN_FIXTURE,
    ]
    for path in required:
        expect(path.is_file(), f"missing required file: {path.relative_to(ROOT)}", errors)


def verify_package_wiring(pbx: str, errors: list[str]) -> None:
    app_target = object_body(pbx, "A70000000000000000000001") or ""
    unit_target = object_body(pbx, "A70000000000000000000002") or ""
    project = object_body(pbx, "A10000000000000000000001") or ""
    local_package = object_body(pbx, "B50000000000000000000001") or ""
    app_product = object_body(pbx, "B60000000000000000000001") or ""
    unit_product = object_body(pbx, "B60000000000000000000002") or ""
    app_frameworks = object_body(pbx, "A80000000000000000000003") or ""
    unit_frameworks = object_body(pbx, "A80000000000000000000006") or ""

    expect("packageProductDependencies" in app_target and "B60000000000000000000001" in app_target, "app target misses RoomScanCore package product", errors)
    expect("packageProductDependencies" in unit_target and "B60000000000000000000002" in unit_target, "unit target misses RoomScanCore package product", errors)
    expect("packageReferences" in project and "B50000000000000000000001" in project, "project misses local package reference", errors)
    expect("isa = XCLocalSwiftPackageReference;" in local_package and "relativePath = .;" in local_package, "local package reference is not project-directory relative to the repository root", errors)
    for product, label in ((app_product, "app"), (unit_product, "unit")):
        expect("isa = XCSwiftPackageProductDependency;" in product, f"{label} package product dependency is missing", errors)
        expect("package = B50000000000000000000001" in product, f"{label} package product has wrong package", errors)
        expect("productName = RoomScanCore;" in product, f"{label} package product has wrong product", errors)
    expect("B4000000000000000000000B" in app_frameworks, "app frameworks phase misses RoomScanCore", errors)
    expect("B4000000000000000000000C" in unit_frameworks, "unit frameworks phase misses RoomScanCore", errors)
    for build_file, product in (
        ("B4000000000000000000000B", "B60000000000000000000001"),
        ("B4000000000000000000000C", "B60000000000000000000002"),
    ):
        body = object_body(pbx, build_file) or ""
        expect(f"productRef = {product}" in body, f"package framework build file {build_file} has wrong product ref", errors)


def verify_project(pbx: str, errors: list[str]) -> None:
    expect("PBXFileSystemSynchronizedRootGroup" not in pbx, "project uses filesystem-synchronized groups", errors)
    expect("isa = PBXGroup;" in pbx, "project has no classic PBXGroup", errors)
    expect("XCRemoteSwiftPackageReference" not in pbx, "project uses a remote Swift package", errors)

    targets = {
        "RoomScanStudio": ("A70000000000000000000001", "A60000000000000000000002"),
        "RoomScanStudioTests": ("A70000000000000000000002", "A60000000000000000000003"),
        "RoomScanStudioUITests": ("A70000000000000000000003", "A60000000000000000000004"),
    }
    for name, (target_id, config_list_id) in targets.items():
        body = object_body(pbx, target_id)
        expect(body is not None, f"missing target: {name}", errors)
        if body is not None:
            expect(f"name = {name};" in body, f"target name mismatch: {name}", errors)
            expect(f"buildConfigurationList = {config_list_id}" in body, f"target missing configuration list: {name}", errors)

    phase_membership = {
        "A80000000000000000000001": [
            "A40000000000000000000001", "A40000000000000000000002", "A40000000000000000000003", "A40000000000000000000004", "A40000000000000000000005", "A40000000000000000000006",
            "B40000000000000000000001", "B40000000000000000000002", "B40000000000000000000003", "B40000000000000000000004", "B40000000000000000000005", "B40000000000000000000006", "B40000000000000000000007", "B40000000000000000000008", "B4000000000000000000000D", "B4000000000000000000000E",
            "D40000000000000000000001", "D40000000000000000000002", "D40000000000000000000003", "D40000000000000000000004",
            "F40000000000000000000001", "F40000000000000000000002",
            "DCBA00000000000000000001", "DCBA00000000000000000002", "DCBA00000000000000000003",
            "ED5000000000000000000001", "ED5000000000000000000002", "ED5000000000000000000003", "ED5000000000000000000004",
            "F60000000000000000000001", "F60000000000000000000002", "F60000000000000000000003", "F60000000000000000000004", "F60000000000000000000005",
        ],
        "A80000000000000000000004": [
            "A4000000000000000000000F", "E40000000000000000000001", "F40000000000000000000003",
            "DCBA00000000000000000004",
            "ED5000000000000000000005",
            "F60000000000000000000006",
        ],
        "A80000000000000000000007": ["A40000000000000000000010"],
        "A80000000000000000000002": [
            "A40000000000000000000007", "A40000000000000000000008", "A40000000000000000000009", "A4000000000000000000000A", "A4000000000000000000000B", "A4000000000000000000000C", "A4000000000000000000000D", "A4000000000000000000000E", "B40000000000000000000009",
            "C40000000000000000000001", "C40000000000000000000003",
        ],
        "A80000000000000000000005": [
            "A40000000000000000000013", "A40000000000000000000014", "A40000000000000000000015", "A40000000000000000000016", "A40000000000000000000017", "A40000000000000000000018", "B4000000000000000000000A",
            "C40000000000000000000002", "C40000000000000000000004",
        ],
    }
    for phase_id, members in phase_membership.items():
        body = object_body(pbx, phase_id)
        expect(body is not None, f"missing build phase: {phase_id}", errors)
        if body is not None:
            for member in members:
                expect(member in body, f"build phase {phase_id} misses member {member}", errors)

    file_reference_map = {
        "A40000000000000000000001": "A20000000000000000000001",
        "A40000000000000000000002": "A20000000000000000000002",
        "A40000000000000000000003": "A20000000000000000000003",
        "A40000000000000000000004": "A20000000000000000000004",
        "A40000000000000000000005": "A20000000000000000000005",
        "A40000000000000000000006": "A20000000000000000000006",
        "A40000000000000000000007": "A20000000000000000000009",
        "A40000000000000000000008": "A20000000000000000000008",
        "A40000000000000000000009": "A2000000000000000000000A",
        "A4000000000000000000000A": "A2000000000000000000000B",
        "A4000000000000000000000B": "A2000000000000000000000C",
        "A4000000000000000000000C": "A2000000000000000000000D",
        "A4000000000000000000000D": "A2000000000000000000000E",
        "A4000000000000000000000E": "A2000000000000000000000F",
        "A4000000000000000000000F": "A20000000000000000000010",
        "A40000000000000000000010": "A20000000000000000000011",
        "A40000000000000000000013": "A2000000000000000000000A",
        "A40000000000000000000014": "A2000000000000000000000B",
        "A40000000000000000000015": "A2000000000000000000000C",
        "A40000000000000000000016": "A2000000000000000000000D",
        "A40000000000000000000017": "A2000000000000000000000E",
        "A40000000000000000000018": "A2000000000000000000000F",
        "B40000000000000000000001": "B20000000000000000000001",
        "B40000000000000000000002": "B20000000000000000000002",
        "B40000000000000000000003": "B20000000000000000000003",
        "B40000000000000000000004": "B20000000000000000000004",
        "B40000000000000000000005": "B20000000000000000000005",
        "B40000000000000000000006": "B20000000000000000000006",
        "B40000000000000000000007": "B20000000000000000000007",
        "B40000000000000000000008": "B20000000000000000000008",
        "B40000000000000000000009": "B20000000000000000000009",
        "B4000000000000000000000A": "B20000000000000000000009",
        "B4000000000000000000000D": "B2000000000000000000000A",
        "B4000000000000000000000E": "B2000000000000000000000B",
        "C40000000000000000000001": "C20000000000000000000001",
        "C40000000000000000000002": "C20000000000000000000001",
        "C40000000000000000000003": "C20000000000000000000002",
        "C40000000000000000000004": "C20000000000000000000002",
        "D40000000000000000000001": "D20000000000000000000001",
        "D40000000000000000000002": "D20000000000000000000002",
        "D40000000000000000000003": "D20000000000000000000003",
        "D40000000000000000000004": "D20000000000000000000004",
        "E40000000000000000000001": "E20000000000000000000001",
        "F40000000000000000000001": "F20000000000000000000001",
        "F40000000000000000000002": "F20000000000000000000002",
        "F40000000000000000000003": "F20000000000000000000003",
        "DCBA00000000000000000001": "ABCD00000000000000000001",
        "DCBA00000000000000000002": "ABCD00000000000000000002",
        "DCBA00000000000000000003": "ABCD00000000000000000003",
        "DCBA00000000000000000004": "ABCD00000000000000000004",
        "ED5000000000000000000001": "ED2000000000000000000001",
        "ED5000000000000000000002": "ED2000000000000000000002",
        "ED5000000000000000000003": "ED2000000000000000000003",
        "ED5000000000000000000004": "ED2000000000000000000004",
        "ED5000000000000000000005": "ED2000000000000000000005",
        "F60000000000000000000001": "F61000000000000000000001",
        "F60000000000000000000002": "F61000000000000000000002",
        "F60000000000000000000003": "F61000000000000000000003",
        "F60000000000000000000004": "F61000000000000000000004",
        "F60000000000000000000005": "F61000000000000000000005",
        "F60000000000000000000006": "F61000000000000000000006",
    }
    for build_file_id, file_reference_id in file_reference_map.items():
        build_file = object_body(pbx, build_file_id) or ""
        expect(f"fileRef = {file_reference_id}" in build_file, f"build file {build_file_id} does not resolve expected file reference", errors)
        expect(object_body(pbx, file_reference_id) is not None, f"missing file reference {file_reference_id}", errors)

    fixture_group = object_body(pbx, "A30000000000000000000008") or ""
    fixtures_group = object_body(pbx, "A30000000000000000000007") or ""
    asset_group = object_body(pbx, "C30000000000000000000001") or ""
    unit_test_group = object_body(pbx, "A3000000000000000000000B") or ""
    capture_group = object_body(pbx, "D30000000000000000000001") or ""
    expect("C30000000000000000000001" in fixture_group, "MockRoom-v1 fixture group misses thumbnail assets group", errors)
    expect("C30000000000000000000002" in fixtures_group, "fixtures group misses RescanFixture-v1", errors)
    expect("C20000000000000000000001" in asset_group, "thumbnail assets group misses PNG reference", errors)
    expect("E20000000000000000000001" in unit_test_group, "unit-test group misses RoomCaptureCoordinatorTests.swift", errors)
    expect("F20000000000000000000003" in unit_test_group, "unit-test group misses AppleCaptureDependencyTests.swift", errors)
    expect("ABCD00000000000000000004" in unit_test_group, "unit-test group misses RoomViewerEditorAppTests.swift", errors)
    expect("ED2000000000000000000005" in unit_test_group, "unit-test group misses RoomExportAppTests.swift", errors)
    expect("F61000000000000000000006" in unit_test_group, "unit-test group misses RoomCloudBackupAppTests.swift", errors)
    expect("F20000000000000000000001" in capture_group, "capture group misses AppleCaptureDependencies.swift", errors)
    expect("F20000000000000000000002" in capture_group, "capture group misses AppleRoomCaptureDriver.swift", errors)
    file_storage_group = object_body(pbx, "B30000000000000000000003") or ""
    room_library_group = object_body(pbx, "B30000000000000000000004") or ""
    expect("B2000000000000000000000A" in file_storage_group, "file storage group misses RescanFixtureLoader.swift", errors)
    expect("B2000000000000000000000B" in room_library_group, "room library group misses RoomRescanFlowView.swift", errors)
    features_group = object_body(pbx, "A30000000000000000000004") or ""
    viewer_group = object_body(pbx, "ABCE00000000000000000001") or ""
    editor_group = object_body(pbx, "ABCE00000000000000000002") or ""
    expect("ABCE00000000000000000001" in features_group, "features group misses RoomViewer", errors)
    expect("ABCE00000000000000000002" in features_group, "features group misses RoomEditor", errors)
    expect("ABCD00000000000000000001" in viewer_group and "ABCD00000000000000000002" in viewer_group, "RoomViewer group misses viewer sources", errors)
    expect("ABCD00000000000000000003" in editor_group, "RoomEditor group misses editor source", errors)
    infrastructure_group = object_body(pbx, "B30000000000000000000001") or ""
    export_group = object_body(pbx, "ED3000000000000000000001") or ""
    expect("ED3000000000000000000001" in infrastructure_group, "infrastructure group misses Export", errors)
    expect(
        all(identifier in export_group for identifier in (
            "ED2000000000000000000001", "ED2000000000000000000002", "ED2000000000000000000003",
        )),
        "Export group misses export infrastructure sources",
        errors,
    )
    expect("ED2000000000000000000004" in room_library_group, "RoomLibrary group misses RoomExportView.swift", errors)
    expect("F61000000000000000000005" in room_library_group, "RoomLibrary group misses RoomCloudBackupViews.swift", errors)
    cloud_backup_group = object_body(pbx, "F62000000000000000000001") or ""
    expect("F62000000000000000000001" in infrastructure_group, "infrastructure group misses CloudBackup", errors)
    expect(
        all(identifier in cloud_backup_group for identifier in (
            "F61000000000000000000001", "F61000000000000000000002", "F61000000000000000000003", "F61000000000000000000004",
        )),
        "CloudBackup group misses backup infrastructure sources",
        errors,
    )

    for config_id in ("A62000000000000000000001", "A62000000000000000000002"):
        body = object_body(pbx, config_id) or ""
        for setting in (
            "INFOPLIST_FILE = RoomScanStudio/Resources/Info.plist;",
            "IPHONEOS_DEPLOYMENT_TARGET = 17.0;",
            "PRODUCT_BUNDLE_IDENTIFIER = org.roomscanstudio.app;",
            'ROOMSCANSTUDIO_PRIVACY_POLICY_URL = "";',
            'TARGETED_DEVICE_FAMILY = "1,2";',
            "GENERATE_INFOPLIST_FILE = NO;",
        ):
            expect(setting in body, f"app build setting missing in {config_id}: {setting}", errors)
    for config_id in ("A63000000000000000000001", "A63000000000000000000002", "A64000000000000000000001", "A64000000000000000000002"):
        body = object_body(pbx, config_id) or ""
        expect("IPHONEOS_DEPLOYMENT_TARGET = 17.0;" in body, f"test deployment target missing in {config_id}", errors)
        expect('TARGETED_DEVICE_FAMILY = "1,2";' in body, f"test device families missing in {config_id}", errors)

    expect(pbx.count("SWIFT_VERSION = 5.0;") == 2, "project Swift language version is not 5.0 in both project configurations", errors)
    forbidden_settings = (
        "DEVELOPMENT_TEAM", "PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER", "CODE_SIGN_ENTITLEMENTS", "com.apple.developer.icloud", "SystemCapabilities",
    )
    for setting in forbidden_settings:
        expect(setting not in pbx, f"forbidden active signing/cloud setting: {setting}", errors)
    expect(not re.search(r"(?m)^\s*path\s*=\s*(?:[A-Za-z]:[\\/]|/)", pbx), "project contains an absolute path", errors)
    verify_package_wiring(pbx, errors)


def verify_scheme(errors: list[str]) -> None:
    try:
        root = element_tree.parse(SCHEME).getroot()
    except (OSError, element_tree.ParseError) as error:
        errors.append(f"invalid shared scheme XML: {error}")
        return
    expect(root.tag == "Scheme", "scheme root is not Scheme", errors)
    blueprint_ids = {reference.attrib.get("BlueprintIdentifier") for reference in root.findall(".//BuildableReference")}
    for target_id in ("A70000000000000000000001", "A70000000000000000000002", "A70000000000000000000003"):
        expect(target_id in blueprint_ids, f"shared scheme misses target {target_id}", errors)


def parse_png_ihdr(data: bytes) -> tuple[tuple[int, int, int, int] | None, list[str]]:
    """Strictly parse PNG chunks with stdlib CRC validation for the AppIcon."""

    errors: list[str] = []
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None, ["AppIcon is not a PNG"]
    if data[8:12] != b"\x00\x00\x00\r" or data[12:16] != b"IHDR":
        return None, ["AppIcon does not begin with a PNG IHDR"]
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    bit_depth = data[24]
    color_type = data[25]
    offset = 8
    has_transparency_chunk = False
    saw_iend = False
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            return None, [*errors, "AppIcon has a truncated PNG chunk"]
        chunk_type = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        declared_crc = int.from_bytes(data[offset + 8 + length:chunk_end], "big")
        actual_crc = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        if declared_crc != actual_crc:
            errors.append("AppIcon has a PNG chunk CRC mismatch")
        if chunk_type == b"tRNS":
            has_transparency_chunk = True
        if chunk_type == b"IEND":
            if length != 0:
                errors.append("AppIcon IEND must not contain payload bytes")
            saw_iend = True
            offset = chunk_end
            break
        offset = chunk_end
    if not saw_iend:
        errors.append("AppIcon is missing a terminal IEND chunk")
    elif offset != len(data):
        errors.append("AppIcon contains trailing bytes after IEND")
    expect(not has_transparency_chunk, "AppIcon must not contain a transparency chunk", errors)
    return (width, height, bit_depth, color_type), errors


def png_ihdr(path: Path, errors: list[str]) -> tuple[int, int, int, int] | None:
    """Read the PNG IHDR without a non-stdlib image dependency."""

    try:
        data = path.read_bytes()
    except OSError as error:
        errors.append(f"cannot read AppIcon PNG: {error}")
        return None
    header, parse_errors = parse_png_ihdr(data)
    errors.extend(parse_errors)
    return header


def _rgb_from_adaptive_palette(source: str, token: str) -> tuple[tuple[float, float, float], tuple[float, float, float]] | None:
    component = r"([0-9]+(?:\.[0-9]+)?)"
    rgb = rf"UIColor\(red:\s*{component},\s*green:\s*{component},\s*blue:\s*{component},\s*alpha:\s*1\)"
    match = re.search(
        rf"static let {re.escape(token)} = adaptive\(\s*light:\s*{rgb},\s*dark:\s*{rgb}\s*\)",
        source,
        re.DOTALL,
    )
    if match is None:
        return None
    values = tuple(float(value) for value in match.groups())
    return values[:3], values[3:]


def _rgb_from_fixed_palette(source: str, token: str) -> tuple[float, float, float] | None:
    component = r"([0-9]+(?:\.[0-9]+)?)"
    match = re.search(
        rf"static let {re.escape(token)} = Color\(red:\s*{component},\s*green:\s*{component},\s*blue:\s*{component}\)",
        source,
    )
    if match is None:
        return None
    return tuple(float(value) for value in match.groups())


def _relative_luminance(rgb: tuple[float, float, float]) -> float:
    def linear(component: float) -> float:
        return component / 12.92 if component <= 0.04045 else ((component + 0.055) / 1.055) ** 2.4

    red, green, blue = (linear(component) for component in rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def _contrast_ratio(foreground: tuple[float, float, float], background: tuple[float, float, float]) -> float:
    brighter = max(_relative_luminance(foreground), _relative_luminance(background))
    darker = min(_relative_luminance(foreground), _relative_luminance(background))
    return (brighter + 0.05) / (darker + 0.05)


def palette_contrast_errors(theme: str) -> list[str]:
    """Check literal semantic palette pairs, not merely role-token spelling."""

    errors: list[str] = []
    adaptive = {token: _rgb_from_adaptive_palette(theme, token) for token in ("paper", "ink", "mutedInk", "blueprint", "amber", "primaryAction")}
    fixed = {token: _rgb_from_fixed_palette(theme, token) for token in ("captureBlack", "primaryOnDark", "mutedOnDark", "blueprintOnDark", "amberOnDark")}
    if any(value is None for value in adaptive.values()) or any(value is None for value in fixed.values()):
        return ["Phase-7 semantic palette literals cannot be parsed for contrast validation"]
    paper = adaptive["paper"]
    assert paper is not None
    for token in ("ink", "mutedInk", "blueprint", "amber"):
        colors = adaptive[token]
        assert colors is not None
        for appearance, foreground, background in (
            ("light", colors[0], paper[0]),
            ("dark", colors[1], paper[1]),
        ):
            ratio = _contrast_ratio(foreground, background)
            if ratio < 4.5:
                errors.append(f"Phase-7 {token} {appearance} contrast is {ratio:.2f}:1, below 4.5:1")
    dark_surface = fixed["captureBlack"]
    assert dark_surface is not None
    for token in ("primaryOnDark", "mutedOnDark", "blueprintOnDark", "amberOnDark"):
        foreground = fixed[token]
        assert foreground is not None
        ratio = _contrast_ratio(foreground, dark_surface)
        if ratio < 4.5:
            errors.append(f"Phase-7 {token} capture-surface contrast is {ratio:.2f}:1, below 4.5:1")
    primary_action = adaptive["primaryAction"]
    white_label = fixed["primaryOnDark"]
    assert primary_action is not None and white_label is not None
    for appearance, background in (("light", primary_action[0]), ("dark", primary_action[1])):
        ratio = _contrast_ratio(white_label, background)
        if ratio < 4.5:
            errors.append(f"Phase-7 primary-action {appearance} label contrast is {ratio:.2f}:1, below 4.5:1")
    for appearance, foreground, background in (
        ("light", primary_action[0], paper[0]),
        ("dark", primary_action[1], paper[1]),
    ):
        ratio = _contrast_ratio(foreground, background)
        if ratio < 3.0:
            errors.append(f"Phase-7 primary-action {appearance} control boundary is {ratio:.2f}:1, below 3.0:1")
    return errors


def workflow_structure_errors(workflow: str) -> list[str]:
    """Small indentation-aware YAML shape check without adding a YAML package."""

    errors: list[str] = []
    lines = [line.rstrip() for line in workflow.splitlines()]

    def indentation(line: str) -> int:
        return len(line) - len(line.lstrip(" "))

    def content(index: int) -> str:
        return lines[index].strip()

    def top_level_index(value: str) -> int | None:
        for index, line in enumerate(lines):
            if indentation(line) == 0 and content(index) == value:
                return index
        return None

    def block_contains(index: int, expected: str) -> bool:
        block_indent = indentation(lines[index])
        for line in lines[index + 1:]:
            if line.strip() and indentation(line) <= block_indent:
                break
            if line.strip() == expected:
                return True
        return False

    permissions = top_level_index("permissions:")
    expect(permissions is not None and block_contains(permissions, "contents: read"), "Phase-7 CI permissions block must be top-level contents: read", errors)
    concurrency = top_level_index("concurrency:")
    expect(concurrency is not None and block_contains(concurrency, "cancel-in-progress: true"), "Phase-7 CI concurrency block must be top-level and cancellable", errors)
    jobs = top_level_index("jobs:")
    expect(jobs is not None, "Phase-7 CI must define a top-level jobs block", errors)
    macos_lines = [index for index in range(len(lines)) if content(index) == "runs-on: macos-15"]
    expect(len(macos_lines) == 1, "Phase-7 CI must have exactly one macos-15 job", errors)

    ordered_steps = (
        "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "run: python3 -B Scripts/verify_xcode_scaffold.py",
        "run: python3 -B Scripts/select_simulators.py --self-test",
        "run: swift test",
        "run: xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj",
        "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    )
    positions: list[int] = []
    for step in ordered_steps:
        matching = [index for index in range(len(lines)) if content(index) == step]
        if len(matching) != 1:
            errors.append(f"Phase-7 CI step must appear exactly once as YAML content: {step}")
        else:
            positions.append(matching[0])
    if positions and positions != sorted(positions):
        errors.append("Phase-7 CI checkout/static/package/artifact steps are out of order")
    return errors


def verify_plists(errors: list[str]) -> None:
    info = read_plist(INFO_PLIST, errors)
    privacy = read_plist(PRIVACY_PLIST, errors)
    expect(bool(info.get("NSCameraUsageDescription")), "missing camera usage description", errors)
    expect(bool(info.get("NSLocationWhenInUseUsageDescription")), "missing location usage description", errors)
    expect(info.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)", "Info.plist must use MARKETING_VERSION substitution", errors)
    expect(info.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)", "Info.plist must use CURRENT_PROJECT_VERSION substitution", errors)
    expect("Prepare capture" in str(info.get("NSCameraUsageDescription", "")), "camera permission copy must describe the explicit Prepare capture action", errors)
    expect("Request GPS" in str(info.get("NSLocationWhenInUseUsageDescription", "")), "location permission copy must describe the explicit Request GPS action", errors)
    expect("RoomScanStudioCloudBackupContainerIdentifier" in info, "missing operator-owned CloudKit container build-setting key", errors)
    expect(
        info.get("RoomScanStudioPrivacyPolicyURL") == "$(ROOMSCANSTUDIO_PRIVACY_POLICY_URL)",
        "missing operator-owned Privacy Policy URL build-setting key",
        errors,
    )
    scene_manifest = info.get("UIApplicationSceneManifest")
    expect(
        isinstance(scene_manifest, dict)
        and scene_manifest.get("UIApplicationSupportsMultipleScenes") is False,
        "V1 capture lease requires UIApplicationSupportsMultipleScenes to be false",
        errors,
    )
    expect(privacy.get("NSPrivacyTracking") is False, "privacy manifest tracking must be false", errors)
    expect(privacy.get("NSPrivacyTrackingDomains") == [], "privacy tracking domains must be empty", errors)
    expect(
        privacy.get("NSPrivacyCollectedDataTypes") == [],
        "current unsigned-off privacy configuration must retain its empty collected-data list until the Account Holder records a release decision",
        errors,
    )
    accessed = privacy.get("NSPrivacyAccessedAPITypes")
    expected_accessed = {
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    }
    actual_accessed = {
        item.get("NSPrivacyAccessedAPIType"): item.get("NSPrivacyAccessedAPITypeReasons")
        for item in accessed
        if isinstance(item, dict)
    } if isinstance(accessed, list) else {}
    expect(actual_accessed == expected_accessed, "privacy manifest required-reason API declarations must be FileTimestamp C617.1 and UserDefaults CA92.1", errors)
    icon = read_json(APP_ICON_DIRECTORY / "Contents.json", errors)
    images = icon.get("images")
    expect(isinstance(images, list) and images, "AppIcon catalog has no image slots", errors)
    expect(any(isinstance(image, dict) and image.get("idiom") == "universal" and image.get("platform") == "ios" and image.get("size") == "1024x1024" and image.get("filename") == "AppIcon-1024.png" for image in images or []), "AppIcon catalog lacks its universal iOS 1024x1024 PNG declaration", errors)
    icon_header = png_ihdr(APP_ICON, errors)
    if icon_header is not None:
        width, height, bit_depth, color_type = icon_header
        expect(width == 1024 and height == 1024, "AppIcon PNG must be exactly 1024x1024", errors)
        expect(bit_depth == 8 and color_type == 2, "AppIcon PNG must be opaque 8-bit RGB (color type 2, no alpha)", errors)


def verify_fixture(errors: list[str]) -> None:
    documents = {
        "manifest": read_json(FIXTURE_ROOT / "manifest.json", errors),
        "metadata": read_json(FIXTURE_ROOT / "metadata.json", errors),
        "revision": read_json(FIXTURE_ROOT / "revisions" / "revision-001" / "revision.json", errors),
        "semantic": read_json(FIXTURE_ROOT / "revisions" / "revision-001" / "semantic-model.json", errors),
        "annotations": read_json(FIXTURE_ROOT / "revisions" / "revision-001" / "annotations.json", errors),
        "measurements": read_json(FIXTURE_ROOT / "revisions" / "revision-001" / "measurements.json", errors),
        "photos": read_json(FIXTURE_ROOT / "revisions" / "revision-001" / "photos.json", errors),
    }
    project_id = "mock-room-v1"
    revision_id = "revision-001"
    manifest = documents["manifest"]
    expect(manifest.get("projectID") == project_id, "fixture manifest project ID is unstable", errors)
    expect(manifest.get("headRevisionID") == revision_id, "fixture head revision ID is unstable", errors)
    expect(manifest.get("revisionIDs") == [revision_id], "fixture revision IDs are inconsistent", errors)
    expect("assetPolicy" not in manifest, "fixture must not contain bogus artifact-policy paths", errors)
    for label, payload in documents.items():
        if label != "manifest":
            expect(payload.get("projectID") == project_id, f"fixture {label} project ID mismatch", errors)
    for label in ("revision", "semantic", "annotations", "measurements", "photos"):
        expect(documents[label].get("revisionID") == revision_id, f"fixture {label} revision ID mismatch", errors)
    expect(documents["revision"].get("immutable") is True, "fixture root revision is not immutable", errors)
    photos = documents["photos"].get("photos")
    expect(isinstance(photos, list) and len(photos) == 1, "fixture photos document must contain one deterministic photo marker", errors)
    if isinstance(photos, list) and photos:
        photo = photos[0]
        expect(isinstance(photo, dict) and photo.get("assetRelativePath") == "photos/reference-001.png", "fixture photo path is missing or unstable", errors)
        transform = photo.get("cameraTransform") if isinstance(photo, dict) else None
        expect(isinstance(transform, dict) and len(transform.get("columnMajorValues", [])) == 16, "fixture photo marker lacks a 4x4 camera transform", errors)
    expect(documents["metadata"].get("thumbnailRelativePath") == "thumbnails/thumbnail.png", "fixture metadata thumbnail path is missing or invalid", errors)
    thumbnail_path = FIXTURE_ROOT / "assets" / "thumbnail.png"
    try:
        thumbnail_signature = thumbnail_path.read_bytes()[:8]
    except OSError as error:
        errors.append(f"cannot read fixture thumbnail: {error}")
        thumbnail_signature = b""
    expect(thumbnail_signature == b"\x89PNG\r\n\x1a\n", "fixture thumbnail is not a PNG", errors)
    structural = documents["semantic"].get("structuralElements")
    movable = documents["semantic"].get("objectElements", documents["semantic"].get("movableElements"))
    expect(isinstance(structural, list) and structural, "fixture lacks structural elements", errors)
    expect(isinstance(movable, list) and movable, "fixture lacks movable elements", errors)
    all_elements = (structural if isinstance(structural, list) else []) + (movable if isinstance(movable, list) else [])
    expect(
        all(isinstance(element, dict) and isinstance(element.get("transform"), dict) and len(element["transform"].get("columnMajorValues", [])) == 16 for element in all_elements),
        "fixture semantic elements lack 4x4 transforms",
        errors,
    )
    expect(any(isinstance(element, dict) and element.get("polygonCorners") for element in structural or []), "fixture structural elements lack polygon corners", errors)
    annotations = documents["annotations"].get("annotations")
    expect(isinstance(annotations, list) and annotations and annotations[0].get("attachedElementID") == "movable-desk-001" and isinstance(annotations[0].get("point"), dict), "fixture lacks an anchored spatial annotation", errors)
    measurements = documents["measurements"].get("measurements")
    expect(isinstance(measurements, list) and measurements and all(isinstance(measurement, dict) and isinstance(measurement.get("startPoint"), dict) and isinstance(measurement.get("endPoint"), dict) for measurement in measurements), "fixture lacks anchored point-to-point measurements", errors)
    expect("not survey-grade" in documents["semantic"].get("accuracyDisclaimer", ""), "fixture lacks accuracy disclaimer", errors)


def verify_rescan_fixture(errors: list[str]) -> None:
    document = read_json(RESCAN_FIXTURE, errors)
    proof = document.get("registrationProof")
    candidate = document.get("candidateSnapshot")
    matches = document.get("matches")
    expect(document.get("fixtureID") == "rescan-fixture-v1", "rescan fixture ID is unstable", errors)
    expect(document.get("simulated") is True, "rescan fixture must be explicitly simulated", errors)
    expect(document.get("sourceFixtureProjectID") == "mock-room-v1", "rescan fixture source project ID is unstable", errors)
    expect(document.get("sourceFixtureBaseRevisionID") == "revision-001", "rescan fixture source revision ID is unstable", errors)
    expect(isinstance(proof, dict), "rescan fixture registration proof is missing", errors)
    if isinstance(proof, dict):
        expect(proof.get("fixtureID") == "rescan-fixture-v1", "rescan fixture proof has wrong fixture ID", errors)
        expect(proof.get("projectID") == "mock-room-v1", "rescan fixture proof has wrong source project", errors)
        expect(proof.get("baseRevisionID") == "revision-001", "rescan fixture proof has wrong source revision", errors)
        expect(proof.get("coordinateFrameID") == "mock-room-v1-frame", "rescan fixture proof has wrong coordinate frame", errors)
        expect(proof.get("proofToken") == "deterministic-rescan-registration-v1", "rescan fixture proof token is unstable", errors)
    expect(isinstance(candidate, dict), "rescan fixture candidate snapshot is missing", errors)
    if isinstance(candidate, dict):
        structural = candidate.get("structuralElements")
        objects = candidate.get("objectElements")
        expect(isinstance(structural, list) and structural, "rescan fixture has no structural candidate elements", errors)
        expect(isinstance(objects, list) and objects, "rescan fixture has no object candidate elements", errors)
        elements = (structural if isinstance(structural, list) else []) + (objects if isinstance(objects, list) else [])
        candidate_ids = [element.get("id") for element in elements if isinstance(element, dict)]
        source_ids = [
            element.get("provenance", {}).get("sourceIdentifier")
            for element in elements
            if isinstance(element, dict) and isinstance(element.get("provenance"), dict)
        ]
        expect(len(candidate_ids) == len(set(candidate_ids)) and all(candidate_ids), "rescan fixture candidate IDs must be unique", errors)
        expect(len(source_ids) == len(elements) and len(source_ids) == len(set(source_ids)) and all(source_ids), "rescan fixture provenance source IDs must be unique", errors)
        for element in elements:
            if not isinstance(element, dict):
                continue
            expect(element.get("origin") == "deterministicFixture", "rescan fixture candidate must declare deterministic origin", errors)
            transform = element.get("transform")
            expect(isinstance(transform, dict) and len(transform.get("columnMajorValues", [])) == 16, "rescan fixture candidate is missing a 4x4 transform", errors)
    expect(isinstance(matches, list) and len(matches) == 5, "rescan fixture must provide an exact five-element fixture bijection", errors)
    if isinstance(matches, list):
        base_ids = [match.get("baseElementID") for match in matches if isinstance(match, dict)]
        mapped_candidate_ids = [match.get("candidateElementID") for match in matches if isinstance(match, dict)]
        expect(len(base_ids) == len(matches) == len(set(base_ids)) and all(base_ids), "rescan fixture base matches are not a bijection", errors)
        expect(len(mapped_candidate_ids) == len(matches) == len(set(mapped_candidate_ids)) and all(mapped_candidate_ids), "rescan fixture candidate matches are not a bijection", errors)
    expect("captureEvidence" not in document, "rescan fixture must not fabricate capture evidence", errors)


def verify_package(errors: list[str]) -> None:
    try:
        manifest = PACKAGE.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"cannot read Package.swift: {error}")
        return
    expect(manifest.startswith("// swift-tools-version: 5.9"), "Package.swift must use Swift tools 5.9", errors)
    expect(".macOS(.v13)" in manifest and ".iOS(.v17)" in manifest, "RoomScanCore package must declare portable macOS and iOS 17 platforms", errors)
    expect('path: "RoomScanCore/Sources/RoomScanCore"' in manifest, "Package.swift does not point core target to real source directory", errors)
    expect('path: "RoomScanCore/Tests/RoomScanCoreTests"' in manifest, "Package.swift does not point test target to real test directory", errors)
    source_root = ROOT / "RoomScanCore" / "Sources" / "RoomScanCore"
    test_root = ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests"
    source_files = sorted(source_root.glob("*.swift"))
    test_files = sorted(test_root.glob("*.swift"))
    expect(bool(source_files), "RoomScanCore has no source files in declared target path", errors)
    expect(bool(test_files), "RoomScanCoreTests has no tests in declared target path", errors)
    for source_path in source_files:
        imports = re.findall(r"(?m)^\s*import\s+([A-Za-z0-9_]+)", source_path.read_text(encoding="utf-8"))
        expect(imports == ["Foundation"], f"non-portable core imports in {source_path.relative_to(ROOT)}: {imports}", errors)
    for test_path in test_files:
        imports = re.findall(r"(?m)^\s*(?:@testable\s+)?import\s+([A-Za-z0-9_]+)", test_path.read_text(encoding="utf-8"))
        expect(set(imports).issubset({"Foundation", "XCTest", "RoomScanCore"}), f"non-portable core test imports in {test_path.relative_to(ROOT)}: {imports}", errors)
    forbidden_write_options = re.compile(
        r"\[\s*\.atomic\s*,\s*\.withoutOverwriting\s*\]"
        r"|\[\s*\.withoutOverwriting\s*,\s*\.atomic\s*\]"
    )
    for swift_path in ROOT.rglob("*.swift"):
        source = swift_path.read_text(encoding="utf-8")
        expect(
            forbidden_write_options.search(source) is None,
            f"Foundation traps when atomic and withoutOverwriting are combined: {swift_path.relative_to(ROOT)}",
            errors,
        )
    expect(
        forbidden_write_options.search("try data.write(to: url, options: [.atomic, .withoutOverwriting])") is not None,
        "verifier self-test did not detect the forbidden Foundation write-option pair",
        errors,
    )


def class_declaration_errors(app_tests: str, ui_tests: str) -> list[str]:
    errors: list[str] = []
    if len(re.findall(r"\bfinal\s+class\s+RoomScanStudioTests\b", app_tests)) != 1:
        errors.append("duplicate or missing RoomScanStudioTests declaration")
    if len(re.findall(r"\bfinal\s+class\s+RoomScanStudioUITests\b", ui_tests)) != 1:
        errors.append("duplicate or missing RoomScanStudioUITests declaration")
    if len(re.findall(r"\b(?:private\s+)?struct\s+FixtureManifest\b", app_tests)) > 1:
        errors.append("duplicate FixtureManifest declaration")
    return errors


def phase2_core_contract_errors(
    models: str,
    store: str,
    reducer: str,
    sha256: str,
) -> list[str]:
    errors: list[str] = []
    for description, contract, source in (
        ("spatial point", "public struct RoomPoint3D", models),
        ("four-by-four transform", "public struct RoomTransform4x4", models),
        ("classification confidence", "public enum RoomClassificationConfidence", models),
        ("element provenance", "public struct RoomElementProvenance", models),
        ("element origin", "public enum RoomElementOrigin", models),
        ("mobility assessment", "public enum RoomMobilityAssessment", models),
        ("revision evidence plan", "public struct RoomRevisionEvidencePlan", models),
        ("revision evidence attachment", "captureEvidence", models),
        ("project schema version contract", "public enum RoomProjectSchemaVersion", models),
        ("strict v2 project default", "RoomProjectSchemaVersion.v2.rawValue", models),
        ("revision evidence compatibility mode", "public enum RoomRevisionEvidenceCompatibility", models),
        ("revision evidence compatibility attachment", "evidenceCompatibility", models),
        ("evidence digest declaration", "sha256Hex", models),
        ("capture/coordinate provenance", "coordinateSpaceEpochID", models),
        ("object-elements JSON migration", "objectElements", models),
        ("legacy movable-elements decoding", "movableElements", models),
        ("atomic initial capture commit", "commitInitialCapture", store),
        ("initial scratch-source boundary", "validateInitialCaptureScratchAssets", store),
        ("revision evidence file validation", "validateRevisionEvidence", store),
        ("evidence byte-count validation", "fileByteCount(of:", store),
        ("evidence digest validation", "try RoomSHA256.hexDigest(ofFile: artifactURL) == declaredDigest", store),
        ("evidence directory closure", "try validateEvidenceDirectoryClosure(", store),
        ("case-insensitive evidence input guard", 'asset.destination.value.lowercased().hasPrefix("evidence/")', store),
        ("case-aliased evidence load guard", "try validateCanonicalEvidenceNamespace(revisionURL: revisionURL, root: root)", store),
        ("semantic mobility placement", "validateSemanticElement", store),
        ("RoomPlan provenance consistency", "validateRoomPlanProvenance", store),
        ("strict RoomPlan element origins", "RoomPlan evidence requires every semantic element to declare an origin.", store),
        ("RoomPlan allowed origin set", "origin == .roomPlan || origin == .manual", store),
        ("validated project schema boundary", "validatedProjectSchemaVersion", store),
        ("validated revision compatibility boundary", "validatedEvidenceCompatibility", store),
        ("historical v1 compatibility gate", "guard projectSchemaVersion == .v1 else", store),
        ("strict public evidence mode", "evidenceCompatibility: .strict", store),
        ("explicit v2 package creation", "schemaVersion: RoomProjectSchemaVersion.v2.rawValue", store),
        ("internal legacy-copy compatibility", "internalCopyEvidenceCompatibility", store),
        ("non-defaulted ordinary revision load", "projectSchemaVersion: RoomProjectSchemaVersion", store),
        ("public planless-evidence write guard", "validateEvidenceAssetInputs", store),
        ("required RoomPlan raw evidence", "evidence/roomplan/captured-room-data.json", store),
        ("fixture evidence omission guard", "case .deterministicFixture", store),
        ("evidence-aware duplicate", "sourceHead.manifest.captureEvidence", store),
        ("capture phase reducer", "public enum RoomCapturePhase", reducer),
        ("attempt-token capture state", "RoomCaptureAttemptToken", reducer),
        ("discard cleanup effect", "cleanupScratch", reducer),
        ("capture teardown effect", "terminateCapture", reducer),
        ("processing cancellation effect", "cancelProcessing", reducer),
        ("RoomPlan coaching mirror", "RoomCaptureCoachingInstruction", reducer),
        ("capture termination mirror", "RoomCaptureTerminationReason", reducer),
        ("live capture termination boundary", "isLiveCapturePhase", reducer),
        ("tracking-quality mirror", "RoomTrackingLimitedReason", reducer),
        ("tokenized GPS effect", "requestGPSAuthorization", reducer),
        ("single-flight reference photo effect", "requestReferencePhoto", reducer),
        ("saving persistence boundary", "acceptsUncommittedAttemptEvents", reducer),
        ("incremental SHA-256", "public enum RoomSHA256", sha256),
        ("bounded evidence hashing", "read(upToCount:", sha256),
    ):
        if contract not in source:
            errors.append(f"Phase-2A core contract is missing: {description}")

    photo_request_case = reducer.partition(
        "case let .requestReferencePhoto(attempt, requestID):"
    )[2].partition("case let .referencePhotoSucceeded")[0]
    expect(
        "state.phase == .scanning" in photo_request_case,
        "Phase-2A core contract is missing: scanning-only reference photo request",
        errors,
    )
    stop_case = reducer.partition("case let .stopRequested(attempt):")[2].partition(
        "case let .didStop"
    )[0]
    expect(
        "state.referencePhotoRequestID == nil" in stop_case,
        "Phase-2A core contract is missing: reference-photo stop guard",
        errors,
    )
    discard_body = reducer.partition("private static func discard(")[2]
    expect(
        "next.referencePhotoRequestID = nil" in discard_body,
        "Phase-2A core contract is missing: reference-photo discard invalidation",
        errors,
    )
    return errors


def phase2b_deterministic_capture_contract_errors(
    capability: str,
    dependencies: str,
    simulated_driver: str,
    coordinator: str,
    capture_view: str,
    environment: str,
    controller: str,
) -> list[str]:
    """Check deterministic/coordinator wiring; Apple source is checked below."""
    errors: list[str] = []
    for description, contract, source in (
        ("RoomPlan-only capture status", "case captureAvailable(sceneMeshAvailable: Bool)", capability),
        ("RoomPlan-only fixture fallback", "return .fixtureMode(missing: [.roomPlanCapture])", capability),
        ("optional mesh status", "return .captureAvailable(sceneMeshAvailable: sceneMeshSupported)", capability),
        ("capture eligibility", "var canStartLiveCapture", capability),
        ("attempt scratch workspace", "final class RoomCaptureScratchWorkspaceFactory", dependencies),
        ("attempt-local scratch explanation", "sibling of, never a child", dependencies),
        ("scratch canonical-root validation", "canonicalRootURL", dependencies),
        ("scratch symlink rejection", "RoomCaptureScratchError.symbolicLink", dependencies),
        ("safe scratch orphan recovery", "recoverOwnedOrphans", dependencies),
        ("throwing scratch cleanup", "func cleanup(_ workspace: RoomCaptureScratchWorkspace) throws", dependencies),
        ("capture driver protocol", "protocol RoomCaptureDriving", dependencies),
        ("async processing cancellation", "func cancelProcessing(attempt: RoomCaptureAttemptToken) async", dependencies),
        ("driver scratch-writer barrier", "func awaitScratchWriteBarrier(for attempt: RoomCaptureAttemptToken) async", dependencies),
        ("RoomPlan final-end ownership gate", "struct RoomCaptureSessionEndObservationGate", dependencies),
        ("attempt-scoped GPS cancellation", "func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async", dependencies),
        ("separate semantic guidance", "case semanticGuidance", dependencies),
        ("separate operational guidance", "case operationalGuidance", dependencies),
        ("deterministic driver", "final class SimulatedRoomCaptureDriver", simulated_driver),
        ("fixture evidence source", "source: .deterministicFixture", simulated_driver),
        ("fixture evidence omissions", "status: .unavailable", simulated_driver),
        ("deterministic processing failure controls", "processingFailuresBeforeSuccess", simulated_driver),
        ("deterministic processing suspension", "suspendsProcessingUntilCancelled", simulated_driver),
        ("capture coordinator", "final class RoomCaptureCoordinator", coordinator),
        ("pure reducer execution", "RoomCaptureReducer.reduce", coordinator),
        ("explicit durable capture commit", "commitInitialCapture(commit, decision: .save)", coordinator),
        ("review snapshot authority", "liveSnapshot = review.commit.draft.revision.semanticSnapshot", coordinator),
        ("tracked capture effect tasks", "effectTasks: [EffectTaskKind: Task<Void, Never>]", coordinator),
        ("synchronous queued-effect cancellation fence", "cancelQueuedAttemptEffects()", coordinator),
        ("cancellation-before-dependency guard", "!Task.isCancelled", coordinator),
        ("scratch writer cancellation barrier", "cancelAndAwaitScratchWriters", coordinator),
        ("driver barrier awaited before cleanup", "await driver.awaitScratchWriteBarrier(for: attempt)", coordinator),
        ("GPS provider cancellation before terminal routing", "await locationProvider.cancelCurrentLocation(for: attempt)", coordinator),
        ("GPS task awaited before terminal routing", "await gpsTask.value", coordinator),
        ("pure guidance merge seam", "static func mergedGuidance", coordinator),
        ("throwing workspace cleanup", "try workspaceFactory.cleanup(workspace)", coordinator),
        ("cleanup retry state", "retryCleanup", coordinator),
        ("capture flow view", "struct RoomCaptureFlowView", capture_view),
        ("black capture canvas", "RoomSemanticCanvas", capture_view),
        ("saving discard boundary", "Discard is intentionally unavailable", capture_view),
        ("blocked navigation back", "navigationBarBackButtonHidden(coordinator.blocksNavigationExit)", capture_view),
        ("blocked interactive dismissal", "interactiveDismissDisabled(coordinator.blocksNavigationExit)", capture_view),
        ("explicit close-discard control", "capture.closeDiscard", capture_view),
        ("cleanup error control", "capture.cleanupError", capture_view),
        ("photo error control", "capture.photoError", capture_view),
        ("mesh capability honesty", "raw mesh is not collected in this version", capture_view),
        ("actionable capture termination copy", "RoomCaptureTerminationPresentation", capture_view),
        ("simulated launch switch", "--use-simulated-capture", environment),
        ("simulated driver injection", "SimulatedRoomCaptureDriverFactory", environment),
        ("production Apple driver injection", "AppleRoomCaptureDriverFactory", environment),
        ("capture scratch root", "CaptureScratch", environment),
        ("single coordinator lease", "RoomCaptureCoordinatorLease", environment),
        ("leased coordinator acquisition", "acquireCaptureCoordinator", environment),
        ("terminal coordinator release", "releaseCaptureCoordinator", environment),
        ("safe scratch startup recovery", "scratchWorkspaceFactory.recoverOwnedOrphans()", environment),
        ("controller capture wrapper", "func commitInitialCapture", controller),
    ):
        if contract not in source:
            errors.append(f"Phase-2B deterministic contract is missing: {description}")

    live_gate_start = coordinator.find("private func acceptsLiveSnapshot")
    live_gate_end = coordinator.find("\n    private func", live_gate_start + 1)
    live_gate_body = "" if live_gate_start < 0 else (
        coordinator[live_gate_start:]
        if live_gate_end < 0
        else coordinator[live_gate_start:live_gate_end]
    )
    expect(
        "case .starting, .scanning, .stopping, .processing:" in live_gate_body,
        "Phase-2B deterministic contract is missing: live-snapshot phase gate",
        errors,
    )

    for identifier in (
        "capture.title", "capture.prepare", "capture.start", "capture.stop",
        "capture.save", "capture.discard", "capture.retry", "capture.cameraDenied",
        "capture.manualLocation", "capture.requestGPS", "capture.gpsDenied",
        "capture.referencePhoto", "capture.photoInFlight", "capture.photoReady", "capture.photoError", "capture.saveError",
        "capture.meshUnavailable", "capture.meshV1Omitted", "capture.termination", "capture.guidance", "capture.closeDiscard", "capture.cleanupError",
        "capture.retryCleanup", "capture.processing",
    ):
        if identifier not in capture_view:
            errors.append(f"Phase-2B deterministic contract is missing accessibility identifier: {identifier}")

    # Apple imports remain isolated from the deterministic driver/coordinator
    # sources. The dedicated production adapter has a separate static contract.
    combined = "\n".join((dependencies, simulated_driver, coordinator, capture_view))
    expect("Task.detached" not in combined, "Phase-2B deterministic capture uses an untracked detached task", errors)
    for forbidden in (
        "import ARKit", "import RoomPlan", "import AVFoundation", "AVCaptureSession(",
        "ARSession.run(", "RoomCaptureSession(", "RoomCaptureSessionDelegate", ".delegate =",
    ):
        if forbidden in combined:
            errors.append(f"Phase-2B deterministic-only source unexpectedly contains: {forbidden}")
    return errors


def phase2b_apple_capture_contract_errors(
    apple_dependencies: str,
    apple_driver: str,
    environment: str,
    mapper: str,
) -> list[str]:
    """Source-level production adapter contract; not an Apple runtime proof."""
    errors: list[str] = []
    for description, contract, source in (
        ("Apple camera provider", "final class AppleCameraPermissionProvider", apple_dependencies),
        ("explicit camera status check", "AVCaptureDevice.authorizationStatus(for: .video)", apple_dependencies),
        ("explicit camera request", "AVCaptureDevice.requestAccess(for: .video)", apple_dependencies),
        ("retained location provider", "final class AppleLocationProvider", apple_dependencies),
        ("explicit when-in-use request", "requestWhenInUseAuthorization()", apple_dependencies),
        ("one-shot location request", "requestLocation()", apple_dependencies),
        ("location delegate proxy", "AppleLocationDelegateProxy", apple_dependencies),
        ("attempt-scoped Apple GPS cancellation", "func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async", apple_dependencies),
        ("per-request location identity", "activeRequestID", apple_dependencies),
        ("matching location continuation finish", "activeRequestID == requestID", apple_dependencies),
        ("defensive location stop", "locationManager?.stopUpdatingLocation()", apple_dependencies),
        ("unavailable location services denial", "return Self.locationServicesResult(servicesEnabled: false)", apple_dependencies),
        ("stale one-shot GPS completion", "nonisolated static func oneShotResult", apple_dependencies),
        ("Apple RoomPlan driver", "final class AppleRoomCaptureDriver", apple_driver),
        ("one injected AR session", "RoomCaptureSession(arSession: arSession)", apple_driver),
        ("RoomCaptureSession delegate", "roomCaptureSession.delegate = delegateProxy", apple_driver),
        ("RoomPlan configuration", "RoomCaptureSession.Configuration()", apple_driver),
        ("RoomPlan coaching enabled", "configuration.isCoachingEnabled = true", apple_driver),
        ("RoomPlan run", "roomCaptureSession.run(configuration: configuration)", apple_driver),
        ("privacy final stop", "roomCaptureSession.stop(pauseARSession: true)", apple_driver),
        ("partial-delta policy", "enum AppleRoomPlanDelegatePayloadKind", apple_driver),
        ("didUpdate-only full snapshot policy", "acceptsFullSnapshot", apple_driver),
        ("final-end observation record", "sessionEndObservationGate.recordDidEnd(for: activeAttempt)", apple_driver),
        ("final-end cleanup barrier", "try await awaitFinalSessionEnd(for: attempt)", apple_driver),
        ("bounded end-timeout error", "case sessionEndNotObserved", apple_driver),
        ("RoomBuilder processing", "RoomBuilder(options: [])", apple_driver),
        ("raw RoomPlan coding", "RoomJSONCoding.makeEncoder().encode(data)", apple_driver),
        ("processed RoomPlan coding", "RoomJSONCoding.makeEncoder().encode(room)", apple_driver),
        ("native USDZ export", "room.export(to: usdzURL, exportOptions: .mesh)", apple_driver),
        ("raw evidence path", "evidence/roomplan/captured-room-data.json", apple_driver),
        ("processed evidence path", "evidence/roomplan/captured-room.json", apple_driver),
        ("native USDZ evidence path", "evidence/native/RoomScan.usdz", apple_driver),
        ("evidence digest", "RoomSHA256.hexDigest(ofFile: url)", apple_driver),
        ("RoomPlan evidence source", "source: .roomPlan", apple_driver),
        ("same-session high-resolution photo", "try await arSession.captureHighResolutionFrame()", apple_driver),
        ("floor surface mapping", "room.floors.map", apple_driver),
        ("documented surface identifier", "surface.identifier", apple_driver),
        ("documented surface parent identifier", "surface.parentIdentifier", apple_driver),
        ("documented object identifier", "object.identifier", apple_driver),
        ("documented object parent identifier", "object.parentIdentifier", apple_driver),
        ("exhaustive object category mapping", "case .washerDryer", apple_driver),
        ("Core mapper", "public enum RoomPlanSemanticMapper", mapper),
        ("RoomPlan mapper provenance", "framework: \"RoomPlan\"", mapper),
        ("RoomPlan mapper attempt IDs", "captureAttemptID: attempt.value", mapper),
        ("production environment driver", "captureDriverFactory = AppleRoomCaptureDriverFactory()", environment),
    ):
        if contract not in source:
            errors.append(f"Phase-2B production adapter contract is missing: {description}")

    for delegate_callback in (
        "didStartWith configuration: RoomCaptureSession.Configuration",
        "didAdd room: CapturedRoom",
        "didRemove room: CapturedRoom",
        "didChange room: CapturedRoom",
        "didUpdate room: CapturedRoom",
        "didProvide instruction: RoomCaptureSession.Instruction",
        "didEndWith data: CapturedRoomData",
    ):
        if delegate_callback not in apple_driver:
            errors.append(f"Phase-2B production adapter is missing delegate callback: {delegate_callback}")

    def delegate_body(marker: str) -> str:
        start = apple_driver.find(marker)
        if start < 0:
            return ""
        next_start = apple_driver.find("\n    func captureSession", start + len(marker))
        return apple_driver[start:] if next_start < 0 else apple_driver[start:next_start]

    for marker in (
        "didAdd room: CapturedRoom",
        "didRemove room: CapturedRoom",
        "didChange room: CapturedRoom",
    ):
        body = delegate_body(marker)
        expect(
            bool(body) and "didReceiveFullRoomSnapshot" not in body,
            f"Phase-2B RoomPlan partial delta must not replace the full snapshot: {marker}",
            errors,
        )
    did_update_body = delegate_body("didUpdate room: CapturedRoom")
    expect(
        "didReceiveFullRoomSnapshot" in did_update_body,
        "Phase-2B RoomPlan didUpdate does not feed the full-snapshot handler",
        errors,
    )

    expect(
        apple_driver.count("ARSession()") == 1,
        "Phase-2B production adapter must construct exactly one ARSession per driver",
        errors,
    )
    for forbidden in (
        "AVCaptureSession(",
        "RoomCaptureView(",
        "UIImagePickerController(",
        "arSession.run(",
        "arSession.delegate",
        "String(describing:)",
        "rawValue",
        "fatalError",
        "captureHighResolutionFrame(using:",
        "currentFrame.capturedImage",
    ):
        if forbidden in apple_driver:
            errors.append(f"Phase-2B production adapter contains forbidden capture path: {forbidden}")
    expect(
        "captureDriverFactory = UnavailableLiveRoomCaptureDriverFactory()" not in environment,
        "Phase-2B production environment still injects the inert capture-driver test seam",
        errors,
    )
    return errors


def phase3_rescan_contract_errors(
    rescan_core: str,
    store: str,
    loader: str,
    flow: str,
    environment: str,
    controller: str,
    detail: str,
) -> list[str]:
    """Static V1-A fixture-only rescan contract; not a live registration proof."""
    errors: list[str] = []
    for description, contract, source in (
        ("Foundation-only rescan engine", "public enum RoomRescanEngine", rescan_core),
        ("typed deterministic registration proof", "RoomDeterministicRescanRegistrationProof", rescan_core),
        ("unproven registration rejection", "throw RoomRescanError.unprovenRegistration", rescan_core),
        ("exact match bijection", "validateExactBijection", rescan_core),
        ("kind mismatch rejection", "base.element.kind == candidate.element.kind", rescan_core),
        ("normalized candidate digest input", "normalized(candidateSnapshot)", rescan_core),
        ("normalized base digest input", "let normalizedBaseSnapshot = normalized(basePayload.semanticSnapshot)", rescan_core),
        ("usable affine candidate transform rejection", "guard let transform = element.transform, isUsableCandidateTransform(transform) else", rescan_core),
        ("deterministic proposal digest", "RoomSHA256.hexDigest(of: data)", rescan_core),
        ("fixture semantic origin", "element.origin == .deterministicFixture", rescan_core),
        ("truthful fixture evidence omissions", "deterministicFixtureEvidencePlan", rescan_core),
        ("store-owned fixture acceptance", "public func acceptFixtureRescan", store),
        ("proposal recomputation under store lock", "RoomRescanEngine.verifyFixtureProposal", store),
        ("fixture-only rescan append gate", "allowsFixtureRescan: true", store),
        ("base photo asset copy", "rescanPhotoAssets", store),
        ("generic rescan append rejection", "case .rescan:", store),
        ("app rescan provider protocol", "protocol RoomRescanProviding", loader),
        ("production unavailable provider", "UnavailableRoomRescanProvider", loader),
        ("fixture provider", "DeterministicFixtureRoomRescanProvider", loader),
        ("unavailable registration reason", ".registrationEvidenceMissing", loader),
        ("fixture loader proposal validation", "RoomRescanEngine.makeFixtureProposal", loader),
        ("fixture-only launch gate", "--use-deterministic-rescan-fixture", environment),
        ("production rescan hard gate", "rescanProvider = UnavailableRoomRescanProvider()", environment),
        ("controller acceptance wrapper", "func acceptFixtureRescan", controller),
        ("detail rescan entry", "detail.rescan", detail),
        ("rescan review view", "struct RoomRescanFlowView", flow),
        ("rescan error-first presentation", "enum RoomRescanFlowPresentation", flow),
        ("rescan status derived from presentation", "RoomRescanFlowPresentation.statusText(for: presentationState)", flow),
    ):
        if contract not in source:
            errors.append(f"Phase-3 V1-A rescan contract is missing: {description}")

    for identifier in (
        "rescan.unavailable", "rescan.status", "rescan.preview", "rescan.accept",
        "rescan.undo", "rescan.accepted",
    ):
        if identifier not in flow:
            errors.append(f"Phase-3 V1-A rescan identifier is missing: {identifier}")

    combined = "\n".join((loader, flow, environment, controller, detail))
    for forbidden in (
        "ARSession(", "RoomCaptureSession(", "AVCaptureSession(", "StructureBuilder",
        "CapturedStructure", "mesh fusion", "appendRevision(",
    ):
        if forbidden in combined:
            errors.append(f"Phase-3 V1-A rescan path contains forbidden implementation: {forbidden}")
    return errors


def phase4_viewer_editor_contract_errors(
    models: str,
    viewer_core: str,
    store: str,
    controller: str,
    detail: str,
    reality_view: str,
    viewer_view: str,
    editor_view: str,
) -> list[str]:
    """Host-static Phase-4 wiring contract, not RealityKit runtime evidence."""
    errors: list[str] = []
    edit_start = store.find("public func commitEditRevision")
    edit_end = store.find("\n    public func", edit_start + 1)
    edit_store = "" if edit_start < 0 else (
        store[edit_start:] if edit_end < 0 else store[edit_start:edit_end]
    )
    for description, contract, source in (
        ("spatial annotation point", "public var point: RoomPoint3D?", models),
        ("annotation attachment", "public var attachedElementID: String?", models),
        ("measurement start point", "public var startPoint: RoomPoint3D?", models),
        ("measurement end point", "public var endPoint: RoomPoint3D?", models),
        ("Foundation viewer camera", "public struct RoomViewerCamera", viewer_core),
        ("pure viewer reducer", "public enum RoomViewerCameraReducer", viewer_core),
        ("viewer root visibility", "public struct RoomViewerVisibility", viewer_core),
        ("copy-on-write editor", "public struct RoomRevisionEditor", viewer_core),
        ("preserving yaw adjustment", "public mutating func adjustPose", viewer_core),
        ("optimistic edit store entry", "public func commitEditRevision", store),
        ("edit expected-head guard", "guard package.manifest.headRevisionID == expectedHeadRevisionID else", edit_store),
        ("edit parent asset carry-forward", "let sourceAssets = try restoredRevisionAssets", edit_store),
        ("immutable edit reason", "reason: .edit", edit_store),
        ("controller safe edit wrapper", "func commitEditRevision", controller),
        ("detail viewer route", "detail.view", detail),
        ("detail editor route", "detail.editRoom", detail),
        ("non-AR RealityKit view", "cameraMode: .nonAR", reality_view),
        ("viewer session auto-config disable", "automaticallyConfigureSession: false", reality_view),
        ("explicit viewer camera", "PerspectiveCamera", reality_view),
        ("viewer root visibility toggle", "isEnabled = visibility.isVisible", reality_view),
        ("semantic box mesh", "MeshResource.generateBox", reality_view),
        ("explicit zero corner radius", "cornerRadius: 0", reality_view),
        ("stored transform application", "Transform(matrix:", reality_view),
        ("scene-plan render cache", "lastScenePlan", reality_view),
        ("main actor RealityKit isolation", "@MainActor", reality_view),
        ("root entity collection cleanup", "root.children.removeAll()", reality_view),
        ("viewer incremental drag state", "previousDragTranslation", viewer_view),
        ("viewer incremental magnification state", "previousMagnificationScale", viewer_view),
        ("viewer no-clip disclosure", "viewer.noClipDisclosure", viewer_view),
        ("viewer visibility controls", "viewer.visibility.structural", viewer_view),
        ("editor explicit save", "editor.save", editor_view),
        ("editor explicit cancel", "editor.cancel", editor_view),
        ("editor pending-form save guard", "applyElementChanges() != .invalid", editor_view),
        ("editor preserves prior revision wording", "never mutates the prior revision", editor_view),
    ):
        if contract not in source:
            errors.append(f"Phase-4 viewer/editor contract is missing: {description}")

    viewer_combined = "\n".join((reality_view, viewer_view))
    for forbidden in (
        "ARSession.run(", "AVCaptureSession(", "AVCaptureDevice.requestAccess", "RoomCaptureSession(",
        "RoomCaptureView(", "UIImagePickerController(",
    ):
        if forbidden in viewer_combined:
            errors.append(f"Phase-4 saved-room viewer contains forbidden AR/camera behavior: {forbidden}")
    return errors


def phase5_export_contract_errors(
    export_models: str,
    store: str,
    crc32: str,
    zip_writer: str,
    builder: str,
    projection: str,
    export_coordinator: str,
    export_service: str,
    derived_provider: str,
    export_view: str,
    environment: str,
    controller: str,
    detail: str,
) -> list[str]:
    """Host-static Phase-5 export wiring, not a ZIP/UIKit runtime proof."""
    errors: list[str] = []
    materialize_start = store.find("public func materializeHeadForExport")
    materialize_end = store.find("\n    public func", materialize_start + 1)
    materialize_body = "" if materialize_start < 0 else (
        store[materialize_start:]
        if materialize_end < 0
        else store[materialize_start:materialize_end]
    )
    cleanup_start = export_service.find("func cleanup(workspaceURL: URL) throws")
    cleanup_end = export_service.find("\n    func", cleanup_start + 1)
    cleanup_body = "" if cleanup_start < 0 else (
        export_service[cleanup_start:]
        if cleanup_end < 0
        else export_service[cleanup_start:cleanup_end]
    )
    for description, contract, source in (
        ("head-only export descriptor", "headRevisionOnly", export_models),
        ("strict ASCII archive names", "unicodeScalars.allSatisfy", export_models),
        ("case-collision archive path guard", "path.value.lowercased()", export_models),
        ("final archive entry cap", "maximumEntries = 4_096", export_models),
        ("reserved materialization entry cap", "maximumMaterializedEntries", export_models),
        ("final archive entry budget", "finalArchiveEntryCount", export_models),
        ("export source-map scope", "RoomExportSourceReferenceScope", export_models),
        ("frozen source-map document", "RoomExportSourceMap", export_models),
        ("store materialization entry point", "public func materializeHeadForExport", store),
        ("materialization root lock", "withRootLock(root)", materialize_body),
        ("materialization expected-head guard", "guard package.manifest.headRevisionID == expectedHeadRevisionID else", materialize_body),
        ("materialization owned stage", "makeExportStagingURL", materialize_body),
        ("materialization deep copy", "deepCopyRegularFile", store),
        ("rewritten export metadata reference", "exportMetadata.thumbnailRelativePath = try RoomRelativePath(mapped)", materialize_body),
        ("rewritten export evidence reference", "evidence.artifacts[index].relativePath = try RoomRelativePath(mapped)", materialize_body),
        ("rewritten export photo reference", "exportPhotos[index].assetRelativePath = try RoomRelativePath(mapped)", materialize_body),
        ("scoped project references", "projectOutboundReferences", materialize_body),
        ("scoped revision references", "revisionOutboundReferences", materialize_body),
        ("source-map materialization", "workspacePath: \"source-map.json\"", materialize_body),
        ("export reference entry closure", "RoomExportEntryPath.validateUnique(entries.map(\\.entryPath))", materialize_body),
        ("materialization source cap", "ExportMaterializationBudget", store),
        ("legacy evidence export boundary", "legacyPlanlessEvidence", store),
        ("attachment output status", "output: .attachments", store),
        ("unavailable evidence output status", "evidenceUnavailable", store),
        ("incremental CRC32", "public enum RoomCRC32", crc32),
        ("CRC lookup table", "ieeeTable", crc32),
        ("classic ZIP profile", "roomscan-zip32-store-v1", zip_writer),
        ("ZIP UTF-8 flag", "utf8Flag", zip_writer),
        ("ZIP STORE method", "storeMethod", zip_writer),
        ("ZIP bounded preflight", "public static func preflight", zip_writer),
        ("ZIP inclusive final entry guard", "inputs.count <= RoomExportLimits.maximumEntries", zip_writer),
        ("ZIP streaming second pass", "copyAndDigest", zip_writer),
        ("ZIP second-pass digest equality", "guard actual == expected else", zip_writer),
        ("ZIP cancellation per chunk", "try Task.checkCancellation()", zip_writer),
        ("ZIP no-overwrite partial", ".withoutOverwriting", zip_writer),
        ("ZIP structural inspector", "public static func inspect", zip_writer),
        ("ZIP exact local closure", "previousLocalEnd == centralOffset", zip_writer),
        ("head export manifest builder", "public enum RoomHeadExportBuilder", builder),
        ("manifest integrity scope", "allEntriesExceptManifest", export_models),
        ("manifest reservation", "manifest.json", builder),
        ("manifest-slot final entry budget", "RoomExportLimits.finalArchiveEntryCount", builder),
        ("complete requested-output status closure", "Set(RoomExportOutput.allCases)", builder),
        ("bounded PNG output", "validatePNG", builder),
        ("bounded PDF output", "maximumPDFPages", builder),
        ("pure bounded floor projection", "maximumRenderableMeters", projection),
        ("transform-aware floor corners", "let corners", projection),
        ("owned export lease marker", "lease-ownership.json", export_service),
        ("marker-proven cleanup", "try validateOwnedLease(workspace)", cleanup_body),
        ("direct marker-only orphan recovery", "func recoverOwnedOrphans", export_service),
        ("non-recursive orphan enumeration", "contentsOfDirectory", export_service),
        ("strict lease marker schema", "roomscan-head-export-lease-v1", export_service),
        ("unambiguous lease marker format constant", "currentFormatVersion", export_service),
        ("export service frozen materialization", "materializeHeadForExport", export_service),
        ("UIKit-only derived provider", "UIGraphicsImageRenderer", derived_provider),
        ("UIKit PDF summary", "UIGraphicsPDFRenderer", derived_provider),
        ("share lifetime coordinator", "completeShare", export_coordinator),
        ("ready lease close cleanup", "discardPreparedExport", export_coordinator),
        ("UIKit share bridge", "UIActivityViewController", export_view),
        ("interactive export dismissal boundary", "interactiveDismissDisabled", export_view),
        ("explicit export route", "detail.export", detail),
        ("export coordinator environment wiring", "exportCoordinator", environment),
        ("startup marker recovery", "exportWorkspaceFactory.recoverOwnedOrphans()", environment),
        ("controller materialization wrapper", "func materializeHeadForExport", controller),
    ):
        if contract not in source:
            errors.append(f"Phase-5 export contract is missing: {description}")

    for identifier in (
        "export.prepare", "export.preparing", "export.share", "export.error",
        "export.retry", "export.retryCleanup", "detail.export",
    ):
        if identifier not in (export_view + detail):
            errors.append(f"Phase-5 export identifier is missing: {identifier}")

    combined = "\n".join((export_models, store, crc32, zip_writer, builder, projection))
    for forbidden in (
        "import UIKit", "import SwiftUI", "import RealityKit", "import ARKit",
        "import RoomPlan", "import SwiftData", "import CloudKit",
    ):
        if forbidden in combined:
            errors.append(f"Phase-5 Core export source contains forbidden framework import: {forbidden}")
    if re.search(r"\bShareLink\s*\(", export_view):
        errors.append("Phase-5 export view uses ShareLink instead of a scoped UIKit share bridge")
    return errors


def phase6_cloud_backup_contract_errors(
    backup_models: str,
    backup_archive: str,
    store: str,
    zip_writer: str,
    cloud_models: str,
    cloud_coordinator: str,
    cloud_service: str,
    apple_transport: str,
    cloud_view: str,
    environment: str,
    controller: str,
) -> list[str]:
    """Host-static Phase-6 backup wiring, never CloudKit runtime proof."""
    errors: list[str] = []
    materialize_start = store.find("public func materializeBackupSnapshot")
    materialize_end = store.find("\n    public func", materialize_start + 1)
    materialize_body = "" if materialize_start < 0 else (
        store[materialize_start:]
        if materialize_end < 0
        else store[materialize_start:materialize_end]
    )
    recovery_start = store.find("public func prepareRecovery")
    recovery_end = store.find("\n    public func", recovery_start + 1)
    recovery_body = "" if recovery_start < 0 else (
        store[recovery_start:]
        if recovery_end < 0
        else store[recovery_start:recovery_end]
    )
    for description, contract, source in (
        ("full-project backup model", "RoomCloudBackupDescriptor", backup_models),
        ("bounded backup archive caps", "maximumPackageEntries = 4_095", backup_models),
        ("indexed app-owned archive names", "RoomBackupArchivePath", backup_models),
        ("case and NFC path rejection", "precomposedStringWithCanonicalMapping", backup_models),
        ("strict deterministic backup archive", "public enum RoomProjectBackupArchive", backup_archive),
        ("canonical signed backup manifest", "RoomJSONCoding.makeEncoder().encode(manifest) == manifestData", backup_archive),
        ("canonical sequential archive mapping", "guard mapping.0.value == expected else", backup_archive),
        ("canonical mapping at backup build", "try validateCanonicalArchiveMapping(\n            materialization.entries.map", backup_archive),
        ("canonical mapping at recovery", "try validateCanonicalArchiveMapping(archiveMapping)", backup_archive),
        ("manifest pre-extraction byte cap", "maximumByteCountByEntryPath", backup_archive),
        ("bounded descriptor validation", "descriptor.fileCount > 0", backup_archive),
        ("full-project materialization entry point", "public func materializeBackupSnapshot", store),
        ("backup root lock", "withRootLock(root)", materialize_body),
        ("backup expected-head guard", "guard package.manifest.headRevisionID == expectedHeadRevisionID else", materialize_body),
        ("full-history ownership validation", "validateBackupRevisionOwnership", store),
        ("backup deep copy", "deepCopyRegularFile", store),
        ("isolated recovery entry point", "public func prepareRecovery", store),
        ("recovery strict extraction", "RoomProjectBackupArchive.extractAndVerify", recovery_body),
        ("prepared recovery discard", "public func discardPreparedRecovery", store),
        ("strict ZIP extraction", "public static func extractVerifiedStoreEntries", zip_writer),
        ("CloudKit-free preference and provider seam", "protocol RoomCloudBackupProviding", cloud_models),
        ("explicit local opt-in preference", "UserDefaults", cloud_models),
        ("bounded cloud listing", "maximumRecords = 200", cloud_models),
        ("bounded malformed-record listing count", "maximumSkippedMalformedRecords = 200", cloud_models),
        ("pure bounded listing accumulator", "RoomCloudBackupListingAccumulator", cloud_models),
        ("cancellation-propagating sleeper", "try await Task.sleep", cloud_models),
        ("one-operation coordinator", "private func begin", cloud_coordinator),
        ("consent-generation gate", "consentGeneration", cloud_coordinator),
        ("bounded retry cancellation check", "try Task.checkCancellation()", cloud_coordinator),
        ("marker-owned backup lease", "backup-workspace-ownership.json", cloud_service),
        ("marker-proven cleanup", "try validateOwnedLease(lease)", cloud_service),
        ("direct marker orphan recovery", "func recoverOwnedOrphans", cloud_service),
        ("post-zone cancellation fence", "A cancelled explicit action must not begin a new upload", cloud_service),
        ("isolated CloudKit import", "import CloudKit", apple_transport),
        ("exact operator container", "CKContainer(identifier: identifier)", apple_transport),
        ("private custom zone", "RoomScanStudioBackupsV1", apple_transport),
        ("content-addressed record type", "RSSProjectBackupV1", apple_transport),
        ("bulk record Result API", "database.records(for:", apple_transport),
        ("metadata-only list desired keys", "descriptorDesiredKeys", apple_transport),
        ("malformed successful descriptor skip", "catch RoomCloudBackupTransportError.malformedRemoteRecord", apple_transport),
        ("per-record CloudKit failure abort", "case let .failure(error): throw mapped(error)", apple_transport),
        ("bounded page loop", "while accumulator.shouldRequestNextPage", apple_transport),
        ("server-unchanged policy", ".ifServerRecordUnchanged", apple_transport),
        ("bounded CKAsset stream", "streamOwnedAsset", apple_transport),
        ("one-byte asset tail probe", "read(upToCount: 1)", apple_transport),
        ("explicit cloud settings UI", "cloudBackup.enable", cloud_view),
        ("recovery dismissal boundary", "interactiveDismissDisabled", cloud_view),
        ("truncated listing disclosure", "cloudBackup.listTruncated", cloud_view),
        ("malformed listing disclosure", "cloudBackup.listMalformed", cloud_view),
        ("published malformed listing count", "skippedMalformedBackupRecordCount", cloud_coordinator),
        ("no launch CloudKit action", "cloudBackupCoordinator", environment),
        ("operator build-setting resolver", "RoomScanStudioCloudBackupContainerIdentifier", environment),
        ("UI-test-only container override", "arguments.contains(\"--ui-testing\")", environment),
        ("startup local marker recovery", "cloudWorkspaceFactory.recoverOwnedOrphans()", environment),
        ("controller recovery wrapper", "func prepareBackupRecovery", controller),
    ):
        if contract not in source:
            errors.append(f"Phase-6 cloud backup contract is missing: {description}")

    for source in (backup_models, backup_archive, store):
        if "import CloudKit" in source:
            errors.append("Phase-6 RoomScanCore source imports CloudKit")
    if "CKContainer.default()" in (cloud_models + cloud_coordinator + cloud_service + apple_transport + cloud_view + environment):
        errors.append("Phase-6 cloud backup uses CKContainer.default() instead of an operator-supplied identifier")
    if "import CloudKit" in (cloud_models + cloud_coordinator + cloud_service + cloud_view + environment):
        errors.append("Phase-6 CloudKit leaked outside AppleCloudBackupTransport")
    return errors


def phase7_release_contract_errors(
    pbx: str,
    theme: str,
    workflow: str,
    selector: str,
    ui_tests: str,
    app_sources: str,
    context_sources: dict[str, str],
) -> list[str]:
    """Host-static release, accessibility, and CI contract; not an Apple build."""

    errors: list[str] = []
    for setting in (
        "MARKETING_VERSION = 1.0.0;",
        "CURRENT_PROJECT_VERSION = 1;",
        "SWIFT_VERSION = 5.0;",
    ):
        if setting not in pbx:
            errors.append(f"Phase-7 release project setting is missing: {setting}")
    if "SWIFT_VERSION = 5.9;" in pbx:
        errors.append("Phase-7 project still uses Swift 5.9 language mode instead of 5.0")

    for description, contract in (
        ("workflow macOS runner", "runs-on: macos-15"),
        ("workflow read-only permissions", "contents: read"),
        ("workflow cancellation concurrency", "cancel-in-progress: true"),
        ("workflow timeout", "timeout-minutes: 45"),
        ("pinned checkout", "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"),
        ("pinned artifact upload", "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"),
        ("host verifier", "python3 -B Scripts/verify_xcode_scaffold.py"),
        ("portable tests", "swift test"),
        ("package resolution", "xcodebuild -resolvePackageDependencies"),
        ("unsigned generic device build", "generic/platform=iOS"),
        ("dynamic selector", "Scripts/select_simulators.py --github-output"),
        ("iPhone destination output", "steps.simulators.outputs.iphone_destination"),
        ("iPad destination output", "steps.simulators.outputs.ipad_destination"),
        ("xcresult artifact", "RoomScanStudio-iPhone.xcresult"),
    ):
        if contract not in workflow:
            errors.append(f"Phase-7 CI contract is missing: {description}")
    errors.extend(workflow_structure_errors(workflow))
    if re.search(r"iPhone\s+[0-9]|iPad\s+[0-9]|iOS-[0-9]", workflow):
        errors.append("Phase-7 CI workflow hardcodes a simulator model or runtime")

    for description, contract in (
        ("pure simulator selection", "def select_latest_ios_destinations"),
        ("synthetic selector self-test", "def _self_test"),
        ("latest runtime sorting", "sorted(runtimes, reverse=True)"),
        ("clear missing-family failure", "both an iPhone and an iPad"),
    ):
        if contract not in selector:
            errors.append(f"Phase-7 simulator selector contract is missing: {description}")

    for description, contract in (
        ("adaptive action row", "struct AdaptiveActionRow"),
        ("Dynamic Type branch", "dynamicTypeSize.isAccessibilitySize"),
        ("compact-width branch", "horizontalSizeClass == .compact"),
        ("fit fallback", "ViewThatFits"),
        ("fixed dark text role", "static let primaryOnDark"),
        ("fixed dark muted role", "static let mutedOnDark"),
    ):
        if contract not in theme:
            errors.append(f"Phase-7 adaptive UI contract is missing: {description}")
    errors.extend(palette_contrast_errors(theme))

    for description, contract in (
        ("strict Privacy Policy URL resolver", "enum PrivacyPolicyURLResolver"),
        ("HTTPS-only Privacy Policy URL guard", 'components.scheme?.lowercased() == "https"'),
        ("decoded control-character rejection", "let percentDecoded = rawValue.removingPercentEncoding"),
        ("Privacy Policy link state", "settings.privacyPolicyLink"),
        ("Privacy Policy unconfigured state", "settings.privacyPolicyNotConfigured"),
    ):
        if contract not in app_sources:
            errors.append(f"Phase-7 privacy-policy source contract is missing: {description}")

    for name in (
        "home", "library", "new_scan", "mock", "capture", "detail", "viewer", "editor", "cloud", "rescan", "export",
    ):
        if "AdaptiveActionRow" not in context_sources.get(name, ""):
            errors.append(f"Phase-7 adaptive action row is missing from {name}")
    for name, required_roles in {
        "home": ("AppPalette.blueprintOnDark", "AppPalette.amberOnDark"),
        "new_scan": ("AppPalette.blueprintOnDark", "AppPalette.amberOnDark"),
        "capture": ("AppPalette.blueprintOnDark", "AppPalette.amberOnDark"),
        "viewer": ("AppPalette.blueprintOnDark",),
        "rescan": ("AppPalette.amberOnDark",),
    }.items():
        source = context_sources.get(name, "")
        if any(role not in source for role in required_roles):
            errors.append(f"Phase-7 fixed-dark surface roles are incomplete in {name}")
    for description, contract, source in (
        ("Home settings/privacy label", "Settings and privacy", context_sources.get("home", "")),
        ("Home Privacy Policy URL injection", "privacyPolicyURL: environment.privacyPolicyURL", context_sources.get("home", "")),
        ("library Privacy Policy URL propagation", "privacyPolicyURL: privacyPolicyURL", context_sources.get("library", "")),
        ("detail Privacy Policy URL propagation", "privacyPolicyURL: privacyPolicyURL", context_sources.get("detail", "")),
        ("in-app Privacy Policy link", "Link(destination: privacyPolicyURL)", context_sources.get("cloud", "")),
        ("unconfigured Privacy Policy disclosure", "Privacy Policy not configured for this build.", context_sources.get("cloud", "")),
    ):
        if contract not in source:
            errors.append(f"Phase-7 privacy-policy UI contract is missing: {description}")
    capture = context_sources.get("capture", "")
    viewer = context_sources.get("viewer", "")
    for description, contract, source in (
        ("capture canvas accessibility label", "accessibilityLabel(\"Live semantic room geometry\")", capture),
        ("capture canvas accessibility hint", "Measurements are estimates, not survey evidence.", capture),
        ("viewer canvas accessibility label", "accessibilityLabel(\"Saved room semantic viewer\")", viewer),
        ("viewer canvas accessibility hint", "Measurements are estimates, not survey geometry.", viewer),
    ):
        if contract not in source:
            errors.append(f"Phase-7 canvas accessibility contract is missing: {description}")
    if ".system(size:" in app_sources:
        errors.append("Phase-7 app source retains fixed user-facing system font sizes")
    for contract in (
        "testAccessibilityDynamicTypeKeepsPrimaryAndMockReviewActionsHittable",
        "UICTContentSizeCategoryAccessibilityXXXL",
        "scrollIntoView",
        "isHittable",
    ):
        if contract not in ui_tests:
            errors.append(f"Phase-7 Dynamic Type UI-test contract is missing: {contract}")
    if "testHomeSettingsDisclosesUnconfiguredPrivacyPolicyWithoutInventingALink" not in ui_tests:
        errors.append("Phase-7 Privacy Policy UI-test contract is missing")
    return errors


def verify_source_contract(errors: list[str]) -> None:
    source_paths = {
        "environment": ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        "index": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomProjectIndex.swift",
        "controller": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
        "fixture": ROOT / "RoomScanStudio" / "Infrastructure" / "FileStorage" / "MockRoomFixtureLoader.swift",
        "rescan_loader": ROOT / "RoomScanStudio" / "Infrastructure" / "FileStorage" / "RescanFixtureLoader.swift",
        "library": ROOT / "RoomScanStudio" / "Features" / "Home" / "ExistingRoomsView.swift",
        "detail": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
        "metadata": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomMetadataEditorView.swift",
        "revision": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RevisionHistoryView.swift",
        "rescan_view": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomRescanFlowView.swift",
        "mock": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "MockRoomReviewView.swift",
        "capture_dependencies": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "RoomCaptureDependencies.swift",
        "simulated_driver": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "SimulatedRoomCaptureDriver.swift",
        "apple_dependencies": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "AppleCaptureDependencies.swift",
        "apple_driver": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "AppleRoomCaptureDriver.swift",
        "capture_coordinator": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureCoordinator.swift",
        "capture_view": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureFlowView.swift",
        "home": ROOT / "RoomScanStudio" / "Features" / "Home" / "HomeView.swift",
        "library": ROOT / "RoomScanStudio" / "Features" / "Home" / "ExistingRoomsView.swift",
        "capability": ROOT / "RoomScanStudio" / "Features" / "Home" / "DeviceCapability.swift",
        "new_scan": ROOT / "RoomScanStudio" / "Features" / "Home" / "NewRoomScanCapabilityView.swift",
        "core": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        "models": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomModels.swift",
        "reducer": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomCaptureReducer.swift",
        "sha256": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomSHA256.swift",
        "mapper": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomPlanSemanticMapper.swift",
        "rescan_core": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomRescan.swift",
        "viewer_core": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomViewerEditor.swift",
        "viewer_reality": ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerRealityView.swift",
        "viewer_view": ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerView.swift",
        "editor_view": ROOT / "RoomScanStudio" / "Features" / "RoomEditor" / "RoomEditorView.swift",
        "export_coordinator": ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "RoomExportCoordinator.swift",
        "export_service": ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "RoomExportService.swift",
        "export_derived": ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "UIKitRoomExportDerivedProvider.swift",
        "export_view": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomExportView.swift",
        "export_models": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomExport.swift",
        "export_crc32": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomCRC32.swift",
        "export_zip": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomDeterministicZIP.swift",
        "export_builder": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomHeadExportBuilder.swift",
        "export_projection": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomFloorPlanProjection.swift",
        "backup_models": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomBackup.swift",
        "backup_archive": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomProjectBackupArchive.swift",
        "cloud_models": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupModels.swift",
        "cloud_coordinator": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupCoordinator.swift",
        "cloud_service": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupService.swift",
        "cloud_apple": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "AppleCloudBackupTransport.swift",
        "cloud_view": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomCloudBackupViews.swift",
    }
    sources = {
        name: path.read_text(encoding="utf-8") if path.is_file() else ""
        for name, path in source_paths.items()
    }
    for name in ("environment", "index", "controller", "fixture", "rescan_loader", "library", "detail", "metadata", "revision", "rescan_view", "mock", "capture_dependencies", "simulated_driver", "apple_dependencies", "apple_driver", "capture_coordinator", "capture_view", "viewer_reality", "viewer_view", "editor_view", "export_coordinator", "export_service", "export_derived", "export_view"):
        expect("import RoomScanCore" in sources[name], f"{name} does not import RoomScanCore", errors)
    expect("RoomCaptureSession.isSupported" in sources["capability"], "capability provider does not use RoomCaptureSession.isSupported", errors)
    expect("ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)" in sources["capability"], "capability provider does not use ARKit mesh support", errors)
    expect("RoomProjectPersistencePolicy" in sources["index"] and "case localOnly" in sources["index"], "SwiftData local-only policy seam is missing", errors)
    expect("groupContainer: .none" in sources["index"], "SwiftData configuration does not explicitly disable group containers", errors)
    expect("cloudKitDatabase: .none" in sources["index"], "SwiftData configuration does not explicitly disable CloudKit", errors)
    expect("@Model" in sources["index"] and "RoomProjectIndexRecord" in sources["index"], "SwiftData index model is missing", errors)
    expect("listProjectListing" in sources["controller"], "library controller does not rebuild from authoritative listing", errors)
    expect("--ui-testing" in sources["environment"] and "--reset-local-store" in sources["environment"], "isolated UI test root arguments are missing", errors)
    expect("applicationSupportDirectory" in sources["environment"], "production Application Support package root is missing", errors)
    expect("enum PrivacyPolicyURLResolver" in sources["environment"], "Privacy Policy URL resolver is missing", errors)
    expect("RoomScanStudioPrivacyPolicyURL" in sources["environment"], "Privacy Policy Info.plist channel is missing", errors)
    expect("try!" not in sources["environment"] and "fatalError" not in sources["environment"], "bootstrap contains a crash-only failure path", errors)
    for identifier in ("library.empty", "library.project.", "library.issues", "detail.editMetadata", "detail.delete", "metadata.roomName", "revision.restore.", "newScan.openMockReview", "mockReview.save", "mockReview.discard"):
        expect(any(identifier in content for content in sources.values()), f"required Phase-1 accessibility identifier missing: {identifier}", errors)
    expect("listProjectListing" in sources["core"], "core corrupt-package listing API is missing", errors)
    expect("allowLegacyPlanlessEvidence" not in sources["core"], "core retains a permissive legacy-evidence load flag", errors)
    expect("validateAppendReason" in sources["core"], "core revision-reason invariant is missing", errors)
    expect("validateStoredRevisionReason" in sources["core"], "core stored-lineage invariant is missing", errors)
    expect("validateProjectAssetPolicyReferences" in sources["core"], "core artifact-policy path validation is missing", errors)
    expect("thumbnailData(projectID:" in sources["core"], "core narrow thumbnail read API is missing", errors)
    expect("effectiveLastRevisedDate" in sources["models"], "core effective freshness property is missing", errors)
    expect("thumbnailDataByProjectID" in sources["controller"], "library controller does not publish thumbnail data", errors)
    expect("thumbnailAsset" in sources["fixture"] and "scope: .project" in sources["fixture"], "fixture loader does not expose project thumbnail input", errors)
    expect("fixturePhotoDestination" in sources["fixture"] and "photos/reference-001.png" in sources["fixture"] and "scope: .revision" in sources["fixture"], "fixture loader does not stage the deterministic photo marker as a revision asset", errors)
    expect("library.thumbnail." in sources["library"] and "detail.thumbnail" in sources["detail"], "thumbnail accessibility identifiers are missing", errors)
    expect("not-included-fixture" not in (FIXTURE_ROOT / "manifest.json").read_text(encoding="utf-8"), "fixture contains a bogus artifact sentinel", errors)
    expect("!gpsRequestInFlight" in sources["reducer"], "capture Save is not blocked while GPS is in flight", errors)
    expect("case cancelGPSAuthorization" in sources["reducer"], "capture termination does not expose attempt-scoped GPS cancellation", errors)
    expect("state.gpsRequestInFlight" in sources["capture_coordinator"], "coordinator does not validate the active GPS request before attaching a fix", errors)
    expect("cancelQueuedAttemptEffects" in sources["capture_coordinator"], "coordinator lacks the synchronous queued-effect cancellation fence", errors)
    expect("!Task.isCancelled" in sources["capture_coordinator"], "coordinator lacks cancellation-before-dependency guards", errors)
    expect("oneShotResult" in sources["apple_dependencies"], "Apple location provider lacks stale one-shot completion handling", errors)

    errors.extend(
        phase2_core_contract_errors(
            sources["models"],
            sources["core"],
            sources["reducer"],
            sources["sha256"],
        )
    )
    errors.extend(
        phase2b_deterministic_capture_contract_errors(
            sources["capability"],
            sources["capture_dependencies"],
            sources["simulated_driver"],
            sources["capture_coordinator"],
            sources["capture_view"],
            sources["environment"],
            sources["controller"],
        )
    )
    errors.extend(
        phase2b_apple_capture_contract_errors(
            sources["apple_dependencies"],
            sources["apple_driver"],
            sources["environment"],
            sources["mapper"],
        )
    )
    errors.extend(
        phase3_rescan_contract_errors(
            sources["rescan_core"],
            sources["core"],
            sources["rescan_loader"],
            sources["rescan_view"],
            sources["environment"],
            sources["controller"],
            sources["detail"],
        )
    )
    errors.extend(
        phase4_viewer_editor_contract_errors(
            sources["models"],
            sources["viewer_core"],
            sources["core"],
            sources["controller"],
            sources["detail"],
            sources["viewer_reality"],
            sources["viewer_view"],
            sources["editor_view"],
        )
    )
    errors.extend(
        phase5_export_contract_errors(
            sources["export_models"],
            sources["core"],
            sources["export_crc32"],
            sources["export_zip"],
            sources["export_builder"],
            sources["export_projection"],
            sources["export_coordinator"],
            sources["export_service"],
            sources["export_derived"],
            sources["export_view"],
            sources["environment"],
            sources["controller"],
            sources["detail"],
        )
    )
    errors.extend(
        phase6_cloud_backup_contract_errors(
            sources["backup_models"],
            sources["backup_archive"],
            sources["core"],
            sources["export_zip"],
            sources["cloud_models"],
            sources["cloud_coordinator"],
            sources["cloud_service"],
            sources["cloud_apple"],
            sources["cloud_view"],
            sources["environment"],
            sources["controller"],
        )
    )
    core_source_directory = ROOT / "RoomScanCore" / "Sources" / "RoomScanCore"
    forbidden_core_imports = (
        "import ARKit",
        "import RoomPlan",
        "import UIKit",
        "import SwiftUI",
        "import RealityKit",
        "import SwiftData",
        "import CloudKit",
    )
    for core_source_path in core_source_directory.glob("*.swift"):
        core_source = core_source_path.read_text(encoding="utf-8")
        for forbidden_import in forbidden_core_imports:
            expect(
                forbidden_import not in core_source,
                f"RoomScanCore imports an Apple UI/capture framework: {forbidden_import}",
                errors,
            )

    # This is intentionally a source-contract check, not a substitute for an
    # Apple-platform compile. It catches a common handoff failure where tests
    # or PBX membership name a Phase-1 type that was never added to the app.
    symbol_definitions = {
        "AppEnvironment": ("environment", "final class AppEnvironment"),
        "RoomProjectRootResolver": ("environment", "enum RoomProjectRootResolver"),
        "RoomProjectIndexRecord": ("index", "RoomProjectIndexRecord"),
        "RoomProjectIndexFactory": ("index", "enum RoomProjectIndexFactory"),
        "RoomProjectIndexRebuilder": ("index", "enum RoomProjectIndexRebuilder"),
        "RoomLibraryController": ("controller", "final class RoomLibraryController"),
        "MockRoomFixtureLoader": ("fixture", "enum MockRoomFixtureLoader"),
        "RoomRescanProviding": ("rescan_loader", "protocol RoomRescanProviding"),
        "UnavailableRoomRescanProvider": ("rescan_loader", "final class UnavailableRoomRescanProvider"),
        "DeterministicFixtureRoomRescanProvider": ("rescan_loader", "final class DeterministicFixtureRoomRescanProvider"),
        "MockRoomReviewPersistenceCoordinator": ("fixture", "struct MockRoomReviewPersistenceCoordinator"),
        "RoomCaptureScratchWorkspaceFactory": ("capture_dependencies", "final class RoomCaptureScratchWorkspaceFactory"),
        "RoomCaptureCoordinatorLease": ("environment", "final class RoomCaptureCoordinatorLease"),
        "SimulatedRoomCaptureDriver": ("simulated_driver", "final class SimulatedRoomCaptureDriver"),
        "AppleCameraPermissionProvider": ("apple_dependencies", "final class AppleCameraPermissionProvider"),
        "AppleLocationProvider": ("apple_dependencies", "final class AppleLocationProvider"),
        "AppleRoomCaptureDriver": ("apple_driver", "final class AppleRoomCaptureDriver"),
        "AppleRoomCaptureDriverFactory": ("apple_driver", "final class AppleRoomCaptureDriverFactory"),
        "RoomPlanSemanticMapper": ("mapper", "public enum RoomPlanSemanticMapper"),
        "RoomCaptureCoordinator": ("capture_coordinator", "final class RoomCaptureCoordinator"),
        "RoomCaptureFlowView": ("capture_view", "struct RoomCaptureFlowView"),
        "RoomDetailView": ("detail", "struct RoomDetailView"),
        "RoomMetadataEditorView": ("metadata", "struct RoomMetadataEditorView"),
        "RevisionHistoryView": ("revision", "struct RevisionHistoryView"),
        "RoomRescanFlowView": ("rescan_view", "struct RoomRescanFlowView"),
        "MockRoomReviewView": ("mock", "struct MockRoomReviewView"),
        "RoomExportCoordinator": ("export_coordinator", "final class RoomExportCoordinator"),
        "RoomExportWorkspaceFactory": ("export_service", "final class RoomExportWorkspaceFactory"),
        "RoomExportService": ("export_service", "final class RoomExportService"),
        "UIKitRoomExportDerivedProvider": ("export_derived", "struct UIKitRoomExportDerivedProvider"),
        "RoomExportView": ("export_view", "struct RoomExportView"),
        "RoomCloudBackupPreferences": ("cloud_models", "final class RoomCloudBackupPreferences"),
        "RoomCloudBackupCoordinator": ("cloud_coordinator", "final class RoomCloudBackupCoordinator"),
        "RoomCloudBackupWorkspaceFactory": ("cloud_service", "final class RoomCloudBackupWorkspaceFactory"),
        "RoomCloudBackupService": ("cloud_service", "final class RoomCloudBackupService"),
        "AppleCloudBackupTransport": ("cloud_apple", "final class AppleCloudBackupTransport"),
        "RoomCloudBackupSettingsView": ("cloud_view", "struct RoomCloudBackupSettingsView"),
    }
    for symbol, (source_name, declaration) in symbol_definitions.items():
        expect(declaration in sources[source_name], f"undefined Phase-1 source contract: {symbol}", errors)

    app_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomScanStudioTests.swift").read_text(encoding="utf-8")
    viewer_editor_app_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomViewerEditorAppTests.swift").read_text(encoding="utf-8")
    export_app_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomExportAppTests.swift").read_text(encoding="utf-8")
    cloud_backup_app_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomCloudBackupAppTests.swift").read_text(encoding="utf-8")
    coordinator_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomCaptureCoordinatorTests.swift").read_text(encoding="utf-8")
    apple_dependency_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "AppleCaptureDependencyTests.swift").read_text(encoding="utf-8")
    ui_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioUITests" / "RoomScanStudioUITests.swift").read_text(encoding="utf-8")
    errors.extend(class_declaration_errors(app_tests, ui_tests))
    expect(
        len(re.findall(r"\bfinal\s+class\s+RoomCaptureCoordinatorTests\b", coordinator_tests)) == 1,
        "duplicate or missing RoomCaptureCoordinatorTests declaration",
        errors,
    )
    expect(
        len(re.findall(r"\bfinal\s+class\s+AppleCaptureDependencyTests\b", apple_dependency_tests)) == 1,
        "duplicate or missing AppleCaptureDependencyTests declaration",
        errors,
    )
    expect(
        len(re.findall(r"\bfinal\s+class\s+RoomViewerEditorAppTests\b", viewer_editor_app_tests)) == 1,
        "duplicate or missing RoomViewerEditorAppTests declaration",
        errors,
    )
    expect(
        len(re.findall(r"\bfinal\s+class\s+RoomExportAppTests\b", export_app_tests)) == 1,
        "duplicate or missing RoomExportAppTests declaration",
        errors,
    )
    expect(
        len(re.findall(r"\bfinal\s+class\s+RoomCloudBackupAppTests\b", cloud_backup_app_tests)) == 1,
        "duplicate or missing RoomCloudBackupAppTests declaration",
        errors,
    )
    for required_test in (
        "testCameraAuthorizationMappingIsPureAndDoesNotRequestHardware",
        "testLocationAuthorizationMappingKeepsNoFixNonfatal",
        "testStaleOneShotLocationCompletesAsNoFixRatherThanLeakingRequest",
        "testRoomPlanDeltaPolicyAcceptsOnlyDidUpdateAsAFullSnapshot",
        "testProductionDriverFactoryDeclaresRoomPlanAvailabilitySeam",
    ):
        expect(required_test in apple_dependency_tests, f"required Apple dependency test is missing: {required_test}", errors)
    for required_test in ("testMockRoomFixtureDecodesAllSevenDocumentsAndSpatialPhotoMarkerAssets", "testInMemoryLocalModelContainerCanBeCreated", "testRoomProjectIndexFactoryUsesLocalOnlyPersistencePolicy", "testIndexRebuildUsesListingAndRemovesStaleRecords", "testMockReviewSaveAndDiscardAreExplicit", "testRoomPlanCaptureGateIsIndependentFromOptionalSceneMesh", "testSimulatedCaptureDriverProducesAnExplicitSaveableFixtureCommit", "testPrivacyPolicyURLResolverAcceptsOnlyConfiguredCredentialFreeHTTPSURLs"):
        expect(required_test in app_tests, f"required app test is missing: {required_test}", errors)
    for required_test in (
        "testReviewSnapshotIsFrozenAgainstLateSameTokenLiveUpdatesAndPersistence",
        "testGuidanceSeparatesSemanticAndOperationalSignalsAndClearsRecoveredState",
        "testSessionEndObservationGateBlocksOwnershipReleaseUntilMatchingEnd",
        "testTerminationPresentationGivesActionableRecoveryCopy",
        "testDiscardAwaitsSuspendedScratchWriterBeforeCleanupAndCreatesNoProfile",
        "testCleanupFailureRetainsDiscardingStateUntilExplicitRetry",
        "testDelayedGPSBlocksSaveAndCannotAttachAfterDiscard",
        "testAuthorizedGPSAndReferencePhotoSavePersistMetadataPhotoDocumentAndBytes",
        "testCoordinatorLeaseReusesTheFirstDriverConstructionUntilTerminalRelease",
        "testScratchFactoryRejectsLinkedRootAndUnsafeCleanupTargetWhenSupported",
        "testCleanupWaitsForFakeFinalEndThenExplicitRetryReleasesWorkspace",
        "testCaptureTerminationCancelsDelayedGPSAndIgnoresLateLocation",
        "testImmediateDiscardCancelsEffectTasksBeforeCameraOrCaptureDependencyEntry",
        "testImmediateDiscardCancelsQueuedStartBeforeDriverEntry",
        "testImmediateDiscardCancelsQueuedGPSBeforeProviderEntry",
        "testImmediateDiscardCancelsQueuedProcessingBeforeDriverEntry",
        "testImmediateDiscardCancelsQueuedReferencePhotoBeforeDriverEntry",
    ):
        expect(required_test in coordinator_tests, f"required capture coordinator test is missing: {required_test}", errors)
    for required_test in ("testEmptyLibraryUsesIsolatedResetStore", "testMockSaveCreatesOneProfileAndDiscardCreatesNone", "testMetadataDuplicateArchiveUnarchiveAndDeleteRequireExplicitActionsAndConfirmation", "testRevisionInspectionAndRestoreCreateNewLineage", "testSimulatedCaptureCanPrepareScanReviewAndSaveOneProfile", "testSimulatedCaptureDiscardCreatesNoProfile", "testSimulatedCameraDenialDoesNotCreateAProfile", "testSimulatedCloseDuringScanningWaitsForCleanupAndCreatesNoProfile", "testSimulatedCloseDuringProcessingWaitsForCleanupAndCreatesNoProfile", "testSimulatedPhotoFailureShowsFeedbackAndReenablesStop", "testSimulatedGPSDenialKeepsManualLocationSaveAvailable", "testSimulatedSaveFailureRetainsReviewThenDiscardCreatesNoProfile", "testSimulatedProcessingFailureCanRetryOnceOrDiscardPersistentlyFailingAttempt"):
        expect(required_test in ui_tests, f"required UI test is missing: {required_test}", errors)
    for required_test in (
        "testProductionRescanProviderIsHardUnavailableWithoutCaptureWork",
        "testRescanFlowPrioritizesAcceptanceErrorOverStaleProposal",
        "testDeterministicRescanFixtureLoadsPreviewAndAcceptsOneChildRevision",
    ):
        expect(required_test in app_tests, f"required Phase-3 app rescan test is missing: {required_test}", errors)
    for required_test in (
        "testProductionRescanPathIsExplicitlyUnavailable",
        "testDeterministicFixtureRescanPreviewUndoAcceptAndRevert",
    ):
        expect(required_test in ui_tests, f"required Phase-3 UI rescan test is missing: {required_test}", errors)
    for required_test in (
        "testViewerScenePlanSeparatesRootsAppliesVisibilityAndCamera",
        "testControllerOptimisticEditCreatesOneRevisionAndRefreshesPackageTruth",
        "testFixturePhotoMarkerAssetStagesOnlyAfterExplicitSave",
    ):
        expect(required_test in viewer_editor_app_tests, f"required Phase-4 app test is missing: {required_test}", errors)
    for required_test in (
        "testFixtureViewerShowsNonARCameraAndVisibilityControls",
        "testEditorSaveCreatesOneEditAndCancelLeavesHeadUnchanged",
        "testEditorBlocksInvalidPendingFormInsteadOfSavingAnUnappliedDraft",
    ):
        expect(required_test in ui_tests, f"required Phase-4 UI test is missing: {required_test}", errors)
    for description, contract in (
        ("persisted editor label assertion", 'XCTAssertEqual(persistedLabel.label, "Main floor Edited")'),
        ("invalid pending form assertion", 'app.staticTexts["editor.error"].waitForExistence(timeout: 5)'),
        ("viewer no-clip assertion", 'app.staticTexts["viewer.noClipDisclosure"].waitForExistence(timeout: 5)'),
    ):
        expect(contract in ui_tests, f"Phase-4 UI contract is missing: {description}", errors)
    for capture_contract in (
        'app.buttons["capture.referencePhoto"].waitForExistence(timeout: 5)',
        'app.staticTexts["capture.photoReady"].waitForExistence(timeout: 5)',
        'identifiedElement("capture.photoError", in: app).waitForExistence(timeout: 5)',
        'identifiedElement("capture.processing", in: app).waitForExistence(timeout: 5)',
        'app.buttons["capture.closeDiscard"].waitForExistence(timeout: 5)',
        '"--use-simulated-capture"',
    ):
        expect(capture_contract in ui_tests, f"deterministic capture UI-test contract is missing: {capture_contract}", errors)
    for description, contract in (
        ("duplicate project wait", 'app.buttons["library.project.ui-project-002"].waitForExistence(timeout: 5)'),
        ("archived project wait", 'app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5)'),
        ("unarchive replacement-action wait", 'app.buttons["detail.archive"].waitForExistence(timeout: 5)'),
        ("deterministic restored head assertion", 'XCTAssertEqual(headRevision.label, "revision-002")'),
        ("restored revision row wait", 'app.buttons["revision.revision-002"].waitForExistence(timeout: 5)'),
        ("edited room-name assertion", 'updatedRoomName.label.contains("Updated")'),
    ):
        expect(contract in ui_tests, f"UI synchronization contract is missing: {description}", errors)
    expect(
        'app.buttons["library.project.ui-project-002"].exists' not in ui_tests,
        "UI duplicate test still uses an immediate project existence check",
        errors,
    )
    for symbol in ("RoomProjectIndexFactory", "RoomProjectIndexRebuilder", "RoomLibraryController", "MockRoomFixtureLoader", "MockRoomReviewPersistenceCoordinator"):
        expect(symbol in app_tests, f"app test references no Phase-1 contract: {symbol}", errors)
    core_transaction_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreTransactionTests.swift").read_text(encoding="utf-8")
    core_lineage_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStorePhase1BTests.swift").read_text(encoding="utf-8")
    reducer_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "CaptureReducerTests.swift").read_text(encoding="utf-8")
    capture_store_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreCaptureTests.swift").read_text(encoding="utf-8")
    mapper_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomPlanSemanticMapperTests.swift").read_text(encoding="utf-8")
    rescan_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomRescanTests.swift").read_text(encoding="utf-8")
    viewer_editor_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomViewerEditorTests.swift").read_text(encoding="utf-8")
    edit_store_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "LocalRoomProjectStoreEditTests.swift").read_text(encoding="utf-8")
    for required_test in ("testThumbnailDataRoundTripsThroughNarrowStoreAPI", "testEffectiveFreshnessAdvancesAcrossAppendAndRestoreWithoutMutatingEvidence", "testDuplicatePreservesHeadAssetReferencesAndCopiesOwnedAssets"):
        expect(required_test in core_transaction_tests, f"required core transaction test is missing: {required_test}", errors)
    for required_test in ("testStoredLineageRejectsLaterInitialMissingRevertSourceAndTemporalRevertSources", "testStoredDuplicateRootRevisionRemainsValid"):
        expect(required_test in core_lineage_tests, f"required core lineage test is missing: {required_test}", errors)
    for required_test in (
        "testStaleCallbackIsIgnoredAndDoesNotAdvanceAttempt",
        "testStartStopAndSaveAreIdempotentAndSaveIsLegalOnlyFromReview",
        "testDiscardAndCancelInvalidatePreCommitAttemptsAndRequestPhaseAppropriateTeardown",
        "testDiscardAndCancelDuringSavingAreIgnoredAfterExplicitSaveConfirmation",
        "testAppleMirrorStateCarriesQualitativeCoachingTerminationAndTracking",
        "testCaptureTerminationIsAcceptedOnlyWhileCaptureIsLive",
        "testGPSAndReferencePhotoRequestsAreTokenizedAndSingleInFlight",
    ):
        expect(required_test in reducer_tests, f"required capture reducer test is missing: {required_test}", errors)
    for description, contract in (
        ("scanning-only reference-photo test setup", "let photoState = RoomCaptureState(phase: .scanning, attemptToken: token)"),
        ("reference-photo stop blocking test", "let stopWhileBusy"),
        ("reference-photo discard teardown test", "let discardedPhoto"),
    ):
        expect(contract in reducer_tests, f"required capture reducer test is missing: {description}", errors)
    for required_test in ("testSHA256KnownVectorAndFileDigest", "testSHA256HardcodedBoundaryVectorsAndFileChunking", "testRoomPlanInitialCommitPromotesDeclaredEvidenceByteForByte", "testDeterministicFixtureEvidenceUsesExplicitOmissionsWithoutBogusPaths", "testDiscardFullyFormedInitialCommitCreatesNoRootAndConsumesNoIdentifiers", "testEvidenceContractFailuresLeaveNoFinalPackageOrStagingResidue", "testInitialCaptureRejectsAssetInputFromConfiguredPackageRoot", "testPublicInitialCaptureAndAppendRejectPlanlessEvidenceAssetInputs", "testStrictV2AndNewV1AppendRejectInjectedCanonicalEvidence", "testEvidenceNamespaceCasingIsRejectedOnPublicWriteAndLoad", "testLegacyPlanlessEvidencePackageLoadsAndPreservesBytesThroughRestoreAndDuplicate", "testRoomPlanProvenanceRejectsMissingOrMismatchedAttemptEpoch", "testRoomPlanEvidenceRequiresCompleteCoordinateBoundElementOrigins", "testTamperedEvidenceFailsClosedOnLoad", "testRestoreAndDuplicatePreserveHeadPhotosEvidenceAndThumbnailBytes", "testStoreRejectsInvalidSpatialGPSAndMeasurementValues", "testStoreAcceptsZeroOutOfPlaneStructuralSurface", "testStoreAllowsFixedAndUnknownObjectMobility", "testStoreRejectsMobilityContradictionsAcrossSemanticArrays", "testLegacyFixtureStyleJSONDecodesWithNilSpatialAndEvidenceFields", "testLegacyMovableElementsDecodeIntoObjectElementsAndNewEncodingUsesObjectElements", "testSpatialProvenanceAndPhotoTransformRoundTrip"):
        expect(required_test in capture_store_tests, f"required capture store test is missing: {required_test}", errors)
    for origin_case in ("RoomElementOrigin.deterministicFixture", ".legacyUnknown"):
        expect(origin_case in capture_store_tests, f"required RoomPlan origin negative control is missing: {origin_case}", errors)
    for required_test in (
        "testMapperPreservesSurfaceProvenanceAndAllowsZeroOutOfPlaneExtent",
        "testMapperKeepsObjectsSeparateAndMapsConservativeMobility",
        "testMapperUsesStableAppOwnedIDsForTheSameSourceWithinOneAttempt",
        "testMapperRejectsNonFiniteOrDegenerateGeometry",
    ):
        expect(required_test in mapper_tests, f"required RoomPlan semantic mapper test is missing: {required_test}", errors)
    expect(
        'RoomRelativePath("Evidence/unlisted.bin")' in capture_store_tests,
        "required case-aliased evidence negative control is missing",
        errors,
    )
    expect(
        'RoomProjectSchemaVersion.v2.rawValue' in capture_store_tests
        and 'XCTAssertEqual(appended.evidenceCompatibility, .strict)' in capture_store_tests
        and '.legacyV1Planless' in capture_store_tests,
        "required v1/v2 evidence compatibility test contract is missing",
        errors,
    )
    expect(
        'destination: try RoomRelativePath("attachments/native-room.usdz")' in core_transaction_tests,
        "Phase-1 generic revision-asset fixture still uses the reserved evidence namespace",
        errors,
    )
    for required_test in (
        "testFixtureProposalPreservesBaseIDsAndUsesCandidateGeometry",
        "testProposalDigestIsDeterministicAcrossMatchInputOrder",
        "testProposalDigestIsDeterministicAcrossCandidateArrayOrder",
        "testProposalDigestIsDeterministicAcrossBaseArrayOrder",
        "testEngineRejectsMissingExtraDuplicateAndLayerOrKindMismatchedMatches",
        "testEngineRejectsInvalidCandidateGeometryAndTamperedProposal",
        "testEngineRejectsZeroSingularAndNonAffineCandidateTransforms",
        "testGenericAppendRejectsRescanReason",
        "testAcceptFixtureRescanCreatesOneImmutableChildAndPreservesParentBytes",
        "testPreviewAndUndoCauseNoStoreMutationAndAcceptRejectsStaleDoubleAndTamperedInput",
        "testFixtureRescanFaultRollsBackAndRetryWithSameIDSucceeds",
    ):
        expect(required_test in rescan_tests, f"required Phase-3 Core rescan test is missing: {required_test}", errors)
    for required_test in (
        "testLegacySpatialDocumentsDecodeWithoutNewSpatialFields",
        "testSpatialAnnotationsAndMeasurementsRoundTrip",
        "testViewerCameraPresetsModesClampsAndRejectsNonFiniteInput",
        "testIncrementalViewerOrbitDeltasMatchOneTotalGestureDelta",
        "testRevisionEditorUsesCopyOnWriteForSemanticSpatialAndPhotoEdits",
        "testRevisionEditorPoseAdjustmentPreservesNonYawCapturedBasis",
        "testRevisionEditorRejectsDanglingAttachmentsInvalidMeasurementAndStructuralLayerViolation",
    ):
        expect(required_test in viewer_editor_tests, f"required Phase-4 Core viewer/editor test is missing: {required_test}", errors)
    for required_test in (
        "testCommitEditRevisionCarriesParentAssetsAndEvidenceWithoutMutatingParent",
        "testCommitEditRevisionRejectsStaleHeadWithoutHistoryMutation",
        "testCommitEditFailureRollsBackAndSameRevisionIDCanRetry",
        "testSpatialValidationRejectsDanglingAnnotation",
        "testSpatialValidationRejectsUnpairedMeasurementEndpoints",
        "testSpatialValidationRejectsMismatchedAnchoredMeasurementValue",
    ):
        expect(required_test in edit_store_tests, f"required Phase-4 Core store test is missing: {required_test}", errors)
    export_core_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomExportTests.swift").read_text(encoding="utf-8")
    for required_test in (
        "testCRC32KnownVectorAndStreamingSHA256AreIncremental",
        "testFinalArchiveEntryBudgetReservesManifestAndDerivedSlots",
        "testZIPInjectedEntryLimitAllowsBoundaryAndRejectsOneMore",
        "testDeterministicZipUsesSortedStoreProfileAndStableBytes",
        "testZipDetectsPostPreflightMutationAndCleansOnlyOwnedPartial",
        "testMaterializeHeadIsHeadOnlyDeepCopiedAndLeavesSourceBytesUntouched",
        "testMaterializationRewritesScopedReferencesWithoutCrossScopeAlias",
        "testHeadExportManifestHasFixtureSkipsAndNativeUSDZByteEqualityWhenDeclared",
    ):
        expect(required_test in export_core_tests, f"required Phase-5 Core export test is missing: {required_test}", errors)
    for required_test in (
        "testCoordinatorPublishesPreparedArchiveAndRetainsLeaseUntilShareCompletion",
        "testShareCompletionCleansOnlyTheFinalizedWorkspaceAndCanRetryCleanup",
        "testControllerMaterializesFixtureHeadWithCanonicalJSONThumbnailAndReferencePhoto",
        "testLeaseRecoveryRemovesOnlyDirectMarkerProvenLeaseAndPreservesLookalikes",
    ):
        expect(required_test in export_app_tests, f"required Phase-5 app export test is missing: {required_test}", errors)
    backup_core_tests = (ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "RoomBackupTests.swift").read_text(encoding="utf-8")
    for required_test in (
        "testBackupMaterializationIsFullHistoryDeepCopiedAndDeterministic",
        "testBackupReaderRejectsIndependentCRCDigestClosureAndNoncanonicalManifestControls",
        "testBackupZIPRejectsSourceMutationBetweenPreflightAndSecondPass",
        "testBackupReaderRejectsOversizedManifestBeforeWritingAndPreservesSentinelDestination",
        "testPreparedRecoveryCanBeDiscardedWithoutPromotingAndTrueV1RecoversExactly",
        "testExactRecoveryNoOpConflictAndRecoverAsCopyRewriteAllIdentifiers",
        "testBackupRejectsCaseAliasedReservedRevisionNamespaces",
        "testBackupRejectsNoncanonicalIndexedArchivePath",
    ):
        expect(required_test in backup_core_tests, f"required Phase-6 Core backup test is missing: {required_test}", errors)
    for required_test in (
        "testDisabledAndEnableOnlyChangeLocalPreferenceWithoutCloudCalls",
        "testEnabledPreferencePersistsLocallyWithFalseDefaultAndNeverCallsTransport",
        "testCheckIsExplicitAndUsesOnlyAccountOperation",
        "testAccountUnavailableIsPublishedWithoutListingOrUploading",
        "testListMissingZoneIsEmptyWithoutCreatingZone",
        "testBackupCreatesZoneAndTreatsSameContentRecordAsIdempotent",
        "testTransientFailureRetriesButLimitExceededDoesNotRetry",
        "testRecoveryConflictCanProceedToExplicitCopyAndCleanupRetryRemainsActionable",
        "testBoundedCloudListingPublishesTruncationInsteadOfRetainingUnboundedRecords",
        "testMalformedSuccessfulDescriptorsAreSkippedWhileValidBackupsRemainAvailable",
        "testListingAccumulatorStopsPagingOnceTheValidRecordCapIsReached",
        "testListTransportFailurePreservesPriorValidListingAndPublishesFailure",
    ):
        expect(required_test in cloud_backup_app_tests, f"required Phase-6 app cloud test is missing: {required_test}", errors)
    for required_test in (
        "testCloudBackupIsDisabledAndUnconfiguredWithoutAutomaticLaunchOperation",
        "testFakeCloudBackupRequiresExplicitListBackupAndRecoverCopyAction",
        "testFakeCloudAccountUnavailableIsVisibleOnlyAfterExplicitCheck",
        "testHomeSettingsDisclosesUnconfiguredPrivacyPolicyWithoutInventingALink",
    ):
        expect(required_test in ui_tests, f"required Phase-6 UI cloud test is missing: {required_test}", errors)
    expect(
        'app.buttons["cloudBackup.prepare"].waitForExistence(timeout: 5)' in ui_tests,
        "Phase-6 UI cloud test does not wait for backup completion before listing/preparing recovery",
        errors,
    )
    expect(
        'app.staticTexts["cloudBackup.recoveryOutcome"].waitForExistence(timeout: 5)' in ui_tests,
        "Phase-6 UI cloud test does not wait for a recovery outcome before closing",
        errors,
    )


def verify_phase7_release(pbx: str, errors: list[str]) -> None:
    document_contracts = {
        ROOT / "README.md": "Phase 7 release evidence",
        ROOT / "CONTRIBUTING.md": "full-SHA GitHub Actions pins",
        ROOT / "SECURITY.md": "Private CloudKit backup is opt-in",
        ROOT / "Docs" / "architecture.md": "Phase 7 release delivery boundary",
        ROOT / "Docs" / "feasibility.md": "Phase 7 release feasibility checkpoint",
        ROOT / "Docs" / "verification-log.md": "Phase 7 release/accessibility/CI checkpoint",
        ROOT / "Docs" / "setup.md": "macOS prerequisites",
        ROOT / "Docs" / "real-device-test-plan.md": "Norwalk YMCA Computer Lab",
        ROOT / "Docs" / "privacy.md": "ROOMSCANSTUDIO_PRIVACY_POLICY_URL",
        ROOT / "Docs" / "storage-performance.md": "4,096 final ZIP entries",
        ROOT / "Docs" / "known-limitations.md": "same-process only",
        ROOT / "Docs" / "release-checklist.md": "Privacy Policy URL",
        ROOT / "Docs" / "dependencies.md": "no third-party dependency",
    }
    for path, contract in document_contracts.items():
        content = path.read_text(encoding="utf-8") if path.is_file() else ""
        expect(contract in content, f"Phase-7 release document contract is missing: {path.relative_to(ROOT)}", errors)
    context_paths = {
        "home": ROOT / "RoomScanStudio" / "Features" / "Home" / "HomeView.swift",
        "library": ROOT / "RoomScanStudio" / "Features" / "Home" / "ExistingRoomsView.swift",
        "new_scan": ROOT / "RoomScanStudio" / "Features" / "Home" / "NewRoomScanCapabilityView.swift",
        "mock": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "MockRoomReviewView.swift",
        "capture": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureFlowView.swift",
        "detail": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
        "viewer": ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerView.swift",
        "editor": ROOT / "RoomScanStudio" / "Features" / "RoomEditor" / "RoomEditorView.swift",
        "cloud": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomCloudBackupViews.swift",
        "rescan": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomRescanFlowView.swift",
        "export": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomExportView.swift",
    }
    required_paths = [APP_THEME, WORKFLOW, SIMULATOR_SELECTOR, ROOT / "RoomScanStudio" / "RoomScanStudioUITests" / "RoomScanStudioUITests.swift", *context_paths.values()]
    if not all(path.is_file() for path in required_paths):
        return
    theme = APP_THEME.read_text(encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")
    selector = SIMULATOR_SELECTOR.read_text(encoding="utf-8")
    ui_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioUITests" / "RoomScanStudioUITests.swift").read_text(encoding="utf-8")
    context_sources = {name: path.read_text(encoding="utf-8") for name, path in context_paths.items()}
    app_sources = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "RoomScanStudio").rglob("*.swift"))
    errors.extend(
        phase7_release_contract_errors(
            pbx,
            theme,
            workflow,
            selector,
            ui_tests,
            app_sources,
            context_sources,
        )
    )


def verify_memory_only_negative_controls(pbx: str, errors: list[str]) -> None:
    package_errors: list[str] = []
    mutated_pbx = pbx.replace("productName = RoomScanCore;", "productName = BrokenCore;", 1)
    verify_package_wiring(mutated_pbx, package_errors)
    expect(bool(package_errors), "verifier self-test did not detect broken package wiring", errors)

    app_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioTests" / "RoomScanStudioTests.swift").read_text(encoding="utf-8")
    ui_tests = (ROOT / "RoomScanStudio" / "RoomScanStudioUITests" / "RoomScanStudioUITests.swift").read_text(encoding="utf-8")
    duplicate_errors = class_declaration_errors(app_tests + "\nfinal class RoomScanStudioTests: XCTestCase {}", ui_tests)
    expect(bool(duplicate_errors), "verifier self-test did not detect duplicate XCTest classes", errors)

    phase7_context_paths = {
        "home": ROOT / "RoomScanStudio" / "Features" / "Home" / "HomeView.swift",
        "library": ROOT / "RoomScanStudio" / "Features" / "Home" / "ExistingRoomsView.swift",
        "new_scan": ROOT / "RoomScanStudio" / "Features" / "Home" / "NewRoomScanCapabilityView.swift",
        "mock": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "MockRoomReviewView.swift",
        "capture": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureFlowView.swift",
        "detail": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
        "viewer": ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerView.swift",
        "editor": ROOT / "RoomScanStudio" / "Features" / "RoomEditor" / "RoomEditorView.swift",
        "cloud": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomCloudBackupViews.swift",
        "rescan": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomRescanFlowView.swift",
        "export": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomExportView.swift",
    }
    phase7_paths = [APP_THEME, WORKFLOW, SIMULATOR_SELECTOR, *phase7_context_paths.values()]
    if all(path.is_file() for path in phase7_paths):
        theme = APP_THEME.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        selector = SIMULATOR_SELECTOR.read_text(encoding="utf-8")
        context_sources = {name: path.read_text(encoding="utf-8") for name, path in phase7_context_paths.items()}
        app_sources = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "RoomScanStudio").rglob("*.swift"))
        baseline_errors = phase7_release_contract_errors(
            pbx, theme, workflow, selector, ui_tests, app_sources, context_sources
        )
        if not baseline_errors:
            low_contrast_theme = theme.replace(
                "light: UIColor(red: 0.31, green: 0.30, blue: 0.27, alpha: 1)",
                "light: UIColor(red: 0.80, green: 0.79, blue: 0.75, alpha: 1)",
                1,
            )
            contrast_errors = phase7_release_contract_errors(
                pbx, low_contrast_theme, workflow, selector, ui_tests, app_sources, context_sources
            )
            expect(bool(contrast_errors), "verifier self-test did not detect a reduced semantic-palette contrast", errors)

            unpinned_workflow = workflow.replace(
                "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
                "actions/checkout@main",
                1,
            )
            workflow_errors = phase7_release_contract_errors(
                pbx, theme, unpinned_workflow, selector, ui_tests, app_sources, context_sources
            )
            expect(bool(workflow_errors), "verifier self-test did not detect an unpinned CI action", errors)

            unsafe_contexts = dict(context_sources)
            unsafe_contexts["capture"] = unsafe_contexts["capture"].replace(
                "AppPalette.blueprintOnDark", "AppPalette.blueprint"
            )
            context_errors = phase7_release_contract_errors(
                pbx, theme, workflow, selector, ui_tests, app_sources, unsafe_contexts
            )
            expect(bool(context_errors), "verifier self-test did not detect a fixed-dark palette misuse", errors)

            weakened_privacy_resolver = app_sources.replace(
                'components.scheme?.lowercased() == "https"',
                "true",
                1,
            )
            privacy_resolver_errors = phase7_release_contract_errors(
                pbx, theme, workflow, selector, ui_tests, weakened_privacy_resolver, context_sources
            )
            expect(
                bool(privacy_resolver_errors),
                "verifier self-test did not detect a weakened Privacy Policy HTTPS guard",
                errors,
            )

    if APP_ICON.is_file():
        icon_bytes = APP_ICON.read_bytes()
        _, valid_icon_errors = parse_png_ihdr(icon_bytes)
        if not valid_icon_errors:
            _, truncated_errors = parse_png_ihdr(icon_bytes[:-1])
            expect(bool(truncated_errors), "verifier self-test did not detect a truncated AppIcon PNG", errors)
            corrupted_icon = bytearray(icon_bytes)
            corrupted_icon[29] ^= 0x01  # IHDR CRC, not source pixel data.
            _, crc_errors = parse_png_ihdr(bytes(corrupted_icon))
            expect(bool(crc_errors), "verifier self-test did not detect an AppIcon PNG CRC mutation", errors)

    models_path = ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomModels.swift"
    store_path = ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift"
    reducer_path = ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomCaptureReducer.swift"
    sha256_path = ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomSHA256.swift"
    if models_path.is_file() and store_path.is_file() and reducer_path.is_file() and sha256_path.is_file():
        models = models_path.read_text(encoding="utf-8")
        store = store_path.read_text(encoding="utf-8")
        reducer = reducer_path.read_text(encoding="utf-8")
        sha256 = sha256_path.read_text(encoding="utf-8")
        if not phase2_core_contract_errors(models, store, reducer, sha256):
            removed_evidence_contract = models.replace(
                "sha256Hex",
                "missingDigest",
            )
            evidence_errors = phase2_core_contract_errors(
                removed_evidence_contract,
                store,
                reducer,
                sha256,
            )
            expect(
                bool(evidence_errors),
                "verifier self-test did not detect a removed evidence contract",
                errors,
            )

            removed_digest_guard = store.replace(
                "try RoomSHA256.hexDigest(ofFile: artifactURL) == declaredDigest",
                "true",
                1,
            )
            digest_guard_errors = phase2_core_contract_errors(
                models,
                removed_digest_guard,
                reducer,
                sha256,
            )
            expect(
                bool(digest_guard_errors),
                "verifier self-test did not detect a removed live evidence digest guard",
                errors,
            )

            removed_closure_call = store.replace(
                "try validateEvidenceDirectoryClosure(evidence, revisionURL: revisionURL, root: root)",
                "()",
                1,
            )
            closure_errors = phase2_core_contract_errors(
                models,
                removed_closure_call,
                reducer,
                sha256,
            )
            expect(
                bool(closure_errors),
                "verifier self-test did not detect a removed evidence-directory closure call",
                errors,
            )

            removed_case_alias_guard = store.replace(
                "try validateCanonicalEvidenceNamespace(revisionURL: revisionURL, root: root)",
                "()",
                1,
            )
            case_alias_errors = phase2_core_contract_errors(
                models,
                removed_case_alias_guard,
                reducer,
                sha256,
            )
            expect(
                bool(case_alias_errors),
                "verifier self-test did not detect a removed case-aliased evidence guard",
                errors,
            )

            removed_v1_compatibility_gate = store.replace(
                "projectSchemaVersion == .v1",
                "projectSchemaVersion == .v2",
                1,
            )
            compatibility_errors = phase2_core_contract_errors(
                models,
                removed_v1_compatibility_gate,
                reducer,
                sha256,
            )
            expect(
                bool(compatibility_errors),
                "verifier self-test did not detect a removed historical-v1 compatibility gate",
                errors,
            )

            removed_strict_public_mode = store.replace(
                "evidenceCompatibility: .strict",
                "evidenceCompatibility: .legacyV1Planless",
            )
            strict_mode_errors = phase2_core_contract_errors(
                models,
                removed_strict_public_mode,
                reducer,
                sha256,
            )
            expect(
                bool(strict_mode_errors),
                "verifier self-test did not detect removed strict public evidence modes",
                errors,
            )

    deterministic_paths = {
        "capability": ROOT / "RoomScanStudio" / "Features" / "Home" / "DeviceCapability.swift",
        "dependencies": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "RoomCaptureDependencies.swift",
        "driver": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "SimulatedRoomCaptureDriver.swift",
        "coordinator": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureCoordinator.swift",
        "view": ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureFlowView.swift",
        "environment": ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        "controller": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
    }
    if all(path.is_file() for path in deterministic_paths.values()):
        deterministic_sources = {
            name: path.read_text(encoding="utf-8")
            for name, path in deterministic_paths.items()
        }
        if not phase2b_deterministic_capture_contract_errors(
            deterministic_sources["capability"],
            deterministic_sources["dependencies"],
            deterministic_sources["driver"],
            deterministic_sources["coordinator"],
            deterministic_sources["view"],
            deterministic_sources["environment"],
            deterministic_sources["controller"],
        ):
            removed_capture_gate = deterministic_sources["capability"].replace(
                "return .captureAvailable(sceneMeshAvailable: sceneMeshSupported)",
                "return .fixtureMode(missing: [.roomPlanCapture])",
                1,
            )
            deterministic_errors = phase2b_deterministic_capture_contract_errors(
                removed_capture_gate,
                deterministic_sources["dependencies"],
                deterministic_sources["driver"],
                deterministic_sources["coordinator"],
                deterministic_sources["view"],
                deterministic_sources["environment"],
                deterministic_sources["controller"],
            )
            expect(
                bool(deterministic_errors),
                "verifier self-test did not detect a removed RoomPlan-only capture gate",
                errors,
            )

            removed_snapshot_gate = deterministic_sources["coordinator"].replace(
                "case .starting, .scanning, .stopping, .processing:",
                "case .starting, .scanning, .stopping:",
                1,
            )
            snapshot_errors = phase2b_deterministic_capture_contract_errors(
                deterministic_sources["capability"],
                deterministic_sources["dependencies"],
                deterministic_sources["driver"],
                removed_snapshot_gate,
                deterministic_sources["view"],
                deterministic_sources["environment"],
                deterministic_sources["controller"],
            )
            expect(
                bool(snapshot_errors),
                "verifier self-test did not detect a weakened live-snapshot phase gate",
                errors,
            )

            removed_writer_barrier = deterministic_sources["coordinator"].replace(
                "await driver.awaitScratchWriteBarrier(for: attempt)",
                "()",
                1,
            )
            barrier_errors = phase2b_deterministic_capture_contract_errors(
                deterministic_sources["capability"],
                deterministic_sources["dependencies"],
                deterministic_sources["driver"],
                removed_writer_barrier,
                deterministic_sources["view"],
                deterministic_sources["environment"],
                deterministic_sources["controller"],
            )
            expect(
                bool(barrier_errors),
                "verifier self-test did not detect a removed scratch-writer barrier",
                errors,
            )

            removed_queue_fence = deterministic_sources["coordinator"].replace(
                "cancelQueuedAttemptEffects()",
                "()",
            )
            queue_fence_errors = phase2b_deterministic_capture_contract_errors(
                deterministic_sources["capability"],
                deterministic_sources["dependencies"],
                deterministic_sources["driver"],
                removed_queue_fence,
                deterministic_sources["view"],
                deterministic_sources["environment"],
                deterministic_sources["controller"],
            )
            expect(
                bool(queue_fence_errors),
                "verifier self-test did not detect a removed queued-effect cancellation fence",
                errors,
            )

    apple_paths = {
        "dependencies": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "AppleCaptureDependencies.swift",
        "driver": ROOT / "RoomScanStudio" / "Infrastructure" / "Capture" / "AppleRoomCaptureDriver.swift",
        "environment": ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        "mapper": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomPlanSemanticMapper.swift",
    }
    if all(path.is_file() for path in apple_paths.values()):
        apple_sources = {
            name: path.read_text(encoding="utf-8")
            for name, path in apple_paths.items()
        }
        if not phase2b_apple_capture_contract_errors(
            apple_sources["dependencies"],
            apple_sources["driver"],
            apple_sources["environment"],
            apple_sources["mapper"],
        ):
            removed_injected_session = apple_sources["driver"].replace(
                "RoomCaptureSession(arSession: arSession)",
                "RoomCaptureSession()",
                1,
            )
            injection_errors = phase2b_apple_capture_contract_errors(
                apple_sources["dependencies"],
                removed_injected_session,
                apple_sources["environment"],
                apple_sources["mapper"],
            )
            expect(
                bool(injection_errors),
                "verifier self-test did not detect removed app-owned ARSession injection",
                errors,
            )

            unsafe_session_driver = apple_sources["driver"] + "\narSession.run(configuration: ARWorldTrackingConfiguration())\n"
            unsafe_session_errors = phase2b_apple_capture_contract_errors(
                apple_sources["dependencies"],
                unsafe_session_driver,
                apple_sources["environment"],
                apple_sources["mapper"],
            )
            expect(
                bool(unsafe_session_errors),
                "verifier self-test did not detect forbidden ARSession.run usage",
                errors,
            )

            unsafe_delta_driver = apple_sources["driver"].replace(
                "owner?.didReceiveRoomDelta(.didAdd)",
                "owner?.didReceiveFullRoomSnapshot(transfer.value)",
                1,
            )
            delta_errors = phase2b_apple_capture_contract_errors(
                apple_sources["dependencies"],
                unsafe_delta_driver,
                apple_sources["environment"],
                apple_sources["mapper"],
            )
            expect(
                bool(delta_errors),
                "verifier self-test did not detect a partial RoomPlan delta replacing the full snapshot",
                errors,
            )

            missing_end_observation_driver = apple_sources["driver"].replace(
                "sessionEndObservationGate.recordDidEnd(for: activeAttempt)",
                "()",
                1,
            )
            end_observation_errors = phase2b_apple_capture_contract_errors(
                apple_sources["dependencies"],
                missing_end_observation_driver,
                apple_sources["environment"],
                apple_sources["mapper"],
            )
            expect(
                bool(end_observation_errors),
                "verifier self-test did not detect a removed RoomPlan final-end observation",
                errors,
            )

            missing_location_cancel_dependencies = apple_sources["dependencies"].replace(
                "func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async",
                "func removedLocationCancellation(for attempt: RoomCaptureAttemptToken) async",
                1,
            )
            location_cancel_errors = phase2b_apple_capture_contract_errors(
                missing_location_cancel_dependencies,
                apple_sources["driver"],
                apple_sources["environment"],
                apple_sources["mapper"],
            )
            expect(
                bool(location_cancel_errors),
                "verifier self-test did not detect removed attempt-scoped GPS cancellation",
                errors,
            )

            removed_photo_api = apple_sources["driver"].replace(
                "try await arSession.captureHighResolutionFrame()",
                "throw AppleRoomCaptureDriverError.referencePhotoEncodingFailed",
                1,
            )
            photo_errors = phase2b_apple_capture_contract_errors(
                apple_sources["dependencies"],
                removed_photo_api,
                apple_sources["environment"],
                apple_sources["mapper"],
            )
            expect(
                bool(photo_errors),
                "verifier self-test did not detect removed same-session high-resolution photo call",
                errors,
            )

    rescan_paths = {
        "core": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomRescan.swift",
        "store": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        "loader": ROOT / "RoomScanStudio" / "Infrastructure" / "FileStorage" / "RescanFixtureLoader.swift",
        "flow": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomRescanFlowView.swift",
        "environment": ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        "controller": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
        "detail": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
    }
    if all(path.is_file() for path in rescan_paths.values()):
        rescan_sources = {
            name: path.read_text(encoding="utf-8")
            for name, path in rescan_paths.items()
        }
        if not phase3_rescan_contract_errors(
            rescan_sources["core"], rescan_sources["store"], rescan_sources["loader"],
            rescan_sources["flow"], rescan_sources["environment"], rescan_sources["controller"],
            rescan_sources["detail"],
        ):
            removed_registration_rejection = rescan_sources["core"].replace(
                "throw RoomRescanError.unprovenRegistration",
                "throw RoomRescanError.invalidCandidateGeometry",
            )
            registration_errors = phase3_rescan_contract_errors(
                removed_registration_rejection, rescan_sources["store"], rescan_sources["loader"],
                rescan_sources["flow"], rescan_sources["environment"], rescan_sources["controller"],
                rescan_sources["detail"],
            )
            expect(
                bool(registration_errors),
                "verifier self-test did not detect a removed unproven-registration rejection",
                errors,
            )

            removed_affine_guard = rescan_sources["core"].replace(
                "isUsableCandidateTransform(transform)",
                "transform.isValid",
                1,
            )
            affine_errors = phase3_rescan_contract_errors(
                removed_affine_guard, rescan_sources["store"], rescan_sources["loader"],
                rescan_sources["flow"], rescan_sources["environment"], rescan_sources["controller"],
                rescan_sources["detail"],
            )
            expect(
                bool(affine_errors),
                "verifier self-test did not detect a removed usable-affine candidate guard",
                errors,
            )

            removed_production_gate = rescan_sources["environment"].replace(
                "rescanProvider = UnavailableRoomRescanProvider()",
                "rescanProvider = DeterministicFixtureRoomRescanProvider()",
                1,
            )
            gate_errors = phase3_rescan_contract_errors(
                rescan_sources["core"], rescan_sources["store"], rescan_sources["loader"],
                rescan_sources["flow"], removed_production_gate, rescan_sources["controller"],
                rescan_sources["detail"],
            )
            expect(
                bool(gate_errors),
                "verifier self-test did not detect a weakened production rescan gate",
                errors,
            )

    phase4_paths = {
        "models": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomModels.swift",
        "viewer_core": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomViewerEditor.swift",
        "store": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        "controller": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
        "detail": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
        "reality": ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerRealityView.swift",
        "viewer": ROOT / "RoomScanStudio" / "Features" / "RoomViewer" / "RoomViewerView.swift",
        "editor": ROOT / "RoomScanStudio" / "Features" / "RoomEditor" / "RoomEditorView.swift",
    }
    if all(path.is_file() for path in phase4_paths.values()):
        phase4_sources = {
            name: path.read_text(encoding="utf-8")
            for name, path in phase4_paths.items()
        }
        if not phase4_viewer_editor_contract_errors(
            phase4_sources["models"], phase4_sources["viewer_core"], phase4_sources["store"],
            phase4_sources["controller"], phase4_sources["detail"], phase4_sources["reality"],
            phase4_sources["viewer"], phase4_sources["editor"],
        ):
            # Materialization has its own head guard. Mutate only the
            # optimistic edit function so this negative control proves the
            # Phase-4 edit contract rather than an earlier unrelated guard.
            edit_start = phase4_sources["store"].find("public func commitEditRevision")
            edit_end = phase4_sources["store"].find("\n    public func", edit_start + 1)
            edit_end = len(phase4_sources["store"]) if edit_end < 0 else edit_end
            edit_body = phase4_sources["store"][edit_start:edit_end]
            mutated_edit_body = edit_body.replace(
                "guard package.manifest.headRevisionID == expectedHeadRevisionID else",
                "guard true else",
                1,
            )
            missing_head_guard = (
                phase4_sources["store"][:edit_start]
                + mutated_edit_body
                + phase4_sources["store"][edit_end:]
            )
            head_errors = phase4_viewer_editor_contract_errors(
                phase4_sources["models"], phase4_sources["viewer_core"], missing_head_guard,
                phase4_sources["controller"], phase4_sources["detail"], phase4_sources["reality"],
                phase4_sources["viewer"], phase4_sources["editor"],
            )
            expect(
                bool(head_errors),
                "verifier self-test did not detect a removed optimistic edit expected-head guard",
                errors,
            )

            missing_asset_carry = phase4_sources["store"].replace(
                "let sourceAssets = try restoredRevisionAssets",
                "let sourceAssets = [] // removed parent asset carry-forward",
                1,
            )
            asset_errors = phase4_viewer_editor_contract_errors(
                phase4_sources["models"], phase4_sources["viewer_core"], missing_asset_carry,
                phase4_sources["controller"], phase4_sources["detail"], phase4_sources["reality"],
                phase4_sources["viewer"], phase4_sources["editor"],
            )
            expect(
                bool(asset_errors),
                "verifier self-test did not detect removed edit parent-asset carry-forward",
                errors,
            )

            unsafe_viewer = phase4_sources["reality"].replace(
                "cameraMode: .nonAR",
                "cameraMode: .ar",
                1,
            )
            viewer_errors = phase4_viewer_editor_contract_errors(
                phase4_sources["models"], phase4_sources["viewer_core"], phase4_sources["store"],
                phase4_sources["controller"], phase4_sources["detail"], unsafe_viewer,
                phase4_sources["viewer"], phase4_sources["editor"],
            )
            expect(
                bool(viewer_errors),
                "verifier self-test did not detect a non-AR viewer regression",
                errors,
            )

    phase5_paths = {
        "models": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomExport.swift",
        "store": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        "crc32": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomCRC32.swift",
        "zip": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomDeterministicZIP.swift",
        "builder": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomHeadExportBuilder.swift",
        "projection": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomFloorPlanProjection.swift",
        "coordinator": ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "RoomExportCoordinator.swift",
        "service": ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "RoomExportService.swift",
        "derived": ROOT / "RoomScanStudio" / "Infrastructure" / "Export" / "UIKitRoomExportDerivedProvider.swift",
        "view": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomExportView.swift",
        "environment": ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        "controller": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
        "detail": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomDetailView.swift",
    }
    if all(path.is_file() for path in phase5_paths.values()):
        phase5_sources = {
            name: path.read_text(encoding="utf-8")
            for name, path in phase5_paths.items()
        }
        if not phase5_export_contract_errors(
            phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
            phase5_sources["zip"], phase5_sources["builder"], phase5_sources["projection"],
            phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
            phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
            phase5_sources["detail"],
        ):
            materialize_start = phase5_sources["store"].find("public func materializeHeadForExport")
            materialize_end = phase5_sources["store"].find("\n    public func", materialize_start + 1)
            materialize_end = len(phase5_sources["store"]) if materialize_end < 0 else materialize_end
            materialize_body = phase5_sources["store"][materialize_start:materialize_end]
            weakened_materialize = materialize_body.replace(
                "guard package.manifest.headRevisionID == expectedHeadRevisionID else",
                "guard true else",
                1,
            )
            removed_head_guard_store = (
                phase5_sources["store"][:materialize_start]
                + weakened_materialize
                + phase5_sources["store"][materialize_end:]
            )
            head_guard_errors = phase5_export_contract_errors(
                phase5_sources["models"], removed_head_guard_store, phase5_sources["crc32"],
                phase5_sources["zip"], phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(head_guard_errors),
                "verifier self-test did not detect a removed export expected-head guard",
                errors,
            )

            removed_rewrite_store = phase5_sources["store"].replace(
                "exportMetadata.thumbnailRelativePath = try RoomRelativePath(mapped)",
                "// removed exported thumbnail rewrite",
                1,
            )
            rewrite_errors = phase5_export_contract_errors(
                phase5_sources["models"], removed_rewrite_store, phase5_sources["crc32"],
                phase5_sources["zip"], phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(rewrite_errors),
                "verifier self-test did not detect a removed export JSON reference rewrite",
                errors,
            )

            removed_marker_cleanup = phase5_sources["service"].replace(
                "try validateOwnedLease(workspace)",
                "()",
                1,
            )
            marker_errors = phase5_export_contract_errors(
                phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
                phase5_sources["zip"], phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], removed_marker_cleanup, phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(marker_errors),
                "verifier self-test did not detect a removed marker-proven export cleanup guard",
                errors,
            )

            removed_zip_equality = phase5_sources["zip"].replace(
                "guard actual == expected else",
                "guard true else",
                1,
            )
            zip_equality_errors = phase5_export_contract_errors(
                phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
                removed_zip_equality, phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(zip_equality_errors),
                "verifier self-test did not detect a removed ZIP second-pass equality guard",
                errors,
            )

            removed_no_overwrite = phase5_sources["zip"].replace(
                ".withoutOverwriting",
                ".atomic",
            )
            no_overwrite_errors = phase5_export_contract_errors(
                phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
                removed_no_overwrite, phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(no_overwrite_errors),
                "verifier self-test did not detect removed ZIP no-overwrite partial creation",
                errors,
            )

            removed_final_entry_guard = phase5_sources["zip"].replace(
                "inputs.count <= RoomExportLimits.maximumEntries",
                "true",
                1,
            )
            final_entry_errors = phase5_export_contract_errors(
                phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
                removed_final_entry_guard, phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(final_entry_errors),
                "verifier self-test did not detect a removed final ZIP entry-cap guard",
                errors,
            )

            removed_output_closure = phase5_sources["builder"].replace(
                "Set(RoomExportOutput.allCases)",
                "Set<RoomExportOutput>()",
                1,
            )
            output_closure_errors = phase5_export_contract_errors(
                phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
                phase5_sources["zip"], removed_output_closure, phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                phase5_sources["view"], phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(output_closure_errors),
                "verifier self-test did not detect a removed requested-output closure",
                errors,
            )

            unsafe_share_view = phase5_sources["view"] + "\nlet unsafeShare = ShareLink(item: URL(string: \"https://example.invalid\")!)\n"
            share_errors = phase5_export_contract_errors(
                phase5_sources["models"], phase5_sources["store"], phase5_sources["crc32"],
                phase5_sources["zip"], phase5_sources["builder"], phase5_sources["projection"],
                phase5_sources["coordinator"], phase5_sources["service"], phase5_sources["derived"],
                unsafe_share_view, phase5_sources["environment"], phase5_sources["controller"],
                phase5_sources["detail"],
            )
            expect(
                bool(share_errors),
                "verifier self-test did not detect a ShareLink lease-lifetime regression",
                errors,
            )

    phase6_paths = {
        "backup_models": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomBackup.swift",
        "backup_archive": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomProjectBackupArchive.swift",
        "store": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        "zip": ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomDeterministicZIP.swift",
        "models": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupModels.swift",
        "coordinator": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupCoordinator.swift",
        "service": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "RoomCloudBackupService.swift",
        "apple": ROOT / "RoomScanStudio" / "Infrastructure" / "CloudBackup" / "AppleCloudBackupTransport.swift",
        "view": ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomCloudBackupViews.swift",
        "environment": ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        "controller": ROOT / "RoomScanStudio" / "Infrastructure" / "Persistence" / "RoomLibraryController.swift",
    }
    if all(path.is_file() for path in phase6_paths.values()):
        phase6_sources = {name: path.read_text(encoding="utf-8") for name, path in phase6_paths.items()}

        def phase6_errors(**overrides: str) -> list[str]:
            values = {**phase6_sources, **overrides}
            return phase6_cloud_backup_contract_errors(
                values["backup_models"], values["backup_archive"], values["store"], values["zip"],
                values["models"], values["coordinator"], values["service"], values["apple"],
                values["view"], values["environment"], values["controller"],
            )

        if not phase6_errors():
            backup_start = phase6_sources["store"].find("public func materializeBackupSnapshot")
            backup_end = phase6_sources["store"].find("\n    public func", backup_start + 1)
            backup_end = len(phase6_sources["store"]) if backup_end < 0 else backup_end
            backup_body = phase6_sources["store"][backup_start:backup_end]
            weakened_backup_body = backup_body.replace(
                "guard package.manifest.headRevisionID == expectedHeadRevisionID else",
                "guard true else",
                1,
            )
            head_errors = phase6_errors(store=(
                phase6_sources["store"][:backup_start] + weakened_backup_body + phase6_sources["store"][backup_end:]
            ))
            expect(bool(head_errors), "verifier self-test did not detect a removed backup expected-head guard", errors)

            canonical_errors = phase6_errors(backup_archive=phase6_sources["backup_archive"].replace(
                "RoomJSONCoding.makeEncoder().encode(manifest) == manifestData",
                "true",
                1,
            ))
            expect(bool(canonical_errors), "verifier self-test did not detect removed canonical backup-manifest validation", errors)

            archive_mapping_errors = phase6_errors(backup_archive=phase6_sources["backup_archive"].replace(
                "guard mapping.0.value == expected else",
                "guard true else",
                1,
            ))
            expect(bool(archive_mapping_errors), "verifier self-test did not detect weakened canonical backup archive mapping", errors)

            malformed_skip_errors = phase6_errors(apple=phase6_sources["apple"].replace(
                "catch RoomCloudBackupTransportError.malformedRemoteRecord",
                "catch RoomCloudBackupTransportError.recordConflict",
                1,
            ))
            expect(bool(malformed_skip_errors), "verifier self-test did not detect removed malformed descriptor isolation", errors)

            paging_errors = phase6_errors(apple=phase6_sources["apple"].replace(
                "while accumulator.shouldRequestNextPage",
                "while true",
                1,
            ))
            expect(bool(paging_errors), "verifier self-test did not detect an unbounded cloud listing page loop", errors)

            cloud_container_errors = phase6_errors(apple=phase6_sources["apple"].replace(
                "CKContainer(identifier: identifier)",
                "CKContainer.default()",
                1,
            ))
            expect(bool(cloud_container_errors), "verifier self-test did not detect default CloudKit container regression", errors)

            policy_errors = phase6_errors(apple=phase6_sources["apple"].replace(
                ".ifServerRecordUnchanged",
                ".allKeys",
                1,
            ))
            expect(bool(policy_errors), "verifier self-test did not detect removed server-unchanged save policy", errors)

            marker_errors = phase6_errors(service=phase6_sources["service"].replace(
                "try validateOwnedLease(lease)",
                "()",
                1,
            ))
            expect(bool(marker_errors), "verifier self-test did not detect removed marker-proven cloud cleanup", errors)

            tail_errors = phase6_errors(apple=phase6_sources["apple"].replace(
                "read(upToCount: 1)",
                "readDataToEndOfFile()",
                1,
            ))
            expect(bool(tail_errors), "verifier self-test did not detect unbounded CKAsset tail read", errors)


def main() -> int:
    errors: list[str] = []
    verify_required_files(errors)
    pbx = ""
    if PROJECT.is_file():
        try:
            pbx = PROJECT.read_text(encoding="utf-8")
            verify_project(pbx, errors)
        except OSError as error:
            errors.append(f"cannot read Xcode project: {error}")
    if SCHEME.is_file():
        verify_scheme(errors)
    if INFO_PLIST.is_file() and PRIVACY_PLIST.is_file():
        verify_plists(errors)
    if FIXTURE_ROOT.is_dir():
        verify_fixture(errors)
    if RESCAN_FIXTURE.is_file():
        verify_rescan_fixture(errors)
    if PACKAGE.is_file():
        verify_package(errors)
    if all(path.is_file() for path in (
        ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomCapture" / "RoomCaptureCoordinator.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "LocalRoomProjectStore.swift",
        ROOT / "RoomScanCore" / "Sources" / "RoomScanCore" / "RoomRescan.swift",
        ROOT / "RoomScanStudio" / "Features" / "RoomLibrary" / "RoomRescanFlowView.swift",
    )):
        verify_source_contract(errors)
    if pbx:
        verify_phase7_release(pbx, errors)
    if pbx:
        verify_memory_only_negative_controls(pbx, errors)

    entitlements = list(ROOT.rglob("*.entitlements"))
    expect(not entitlements, "active entitlements file present: " + ", ".join(str(path.relative_to(ROOT)) for path in entitlements), errors)
    expect(not (ROOT / "Package.resolved").exists(), "Package.resolved is not allowed for the local package scaffold", errors)
    generated_python_artifacts = list(ROOT.rglob("__pycache__")) + list(ROOT.rglob("*.pyc")) + list(ROOT.rglob("*.pyo"))
    expect(not generated_python_artifacts, "generated Python cache present: " + ", ".join(str(path.relative_to(ROOT)) for path in generated_python_artifacts), errors)

    if errors:
        print("static structure failed")
        for error in errors:
            print(f"- {error}")
        return 1
    print("static structure passed")
    print("evidence limitation: static host checks only; Phase-7 verifies prior-phase fixture/PBX/privacy boundaries plus release substitutions, an opaque-RGB AppIcon PNG structure, literal palette contrast, adaptive-action/Dynamic-Type source and UI-test contracts, and a pinned macOS CI/simulator-selector design, but no Xcode build, Swift tests, Simulator, RealityKit render, Accessibility Inspector, asset-catalog compilation, device, LiDAR registration, ARWorldMap relocalization, CloudKit development-container call, entitlement/profile, CKAsset upload/download, ZIP consumer inspection, PNG/PDF rendering, native USDZ export, or system share handoff was performed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
