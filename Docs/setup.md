# Setup

## Evidence status

- Verified on Windows: repository structure, JSON/plist/XML parsing, icon header, and source contracts only.
- Verified on macOS CI: package resolution, 122/122 `RoomScanCore` tests, the unsigned generic iOS build, and 62 app plus 25 UI tests on each selected iPhone/iPad Simulator in run 31359458769.
- Pending external evidence: physical-device capture, CloudKit development-container operations, share handoff, and archive inspection.

## macOS prerequisites

Use a Mac with a current Xcode installation that includes an iOS 18-or-later
SDK. This repository intentionally has no committed development team,
provisioning profile, CloudKit entitlement, or container identifier. Resolve the
local package and use the shared scheme:

    xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj
    swift test
    xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

For Simulator tests, select currently available iPhone and iPad destinations;
the CI helper does this without a model/runtime assumption:

    python3 Scripts/select_simulators.py --self-test
    xcrun simctl list devices available -j

Then run the Xcode test scheme separately on one discovered iPhone UUID and
one discovered iPad UUID. The hosted workflow runs this sequence dynamically;
physical-device checks still require the release operator's Mac and devices.

## Optional private backup configuration

Cloud backup remains disabled by default. A build operator may supply an exact
resolved `ROOMSCANSTUDIO_CLOUD_BACKUP_CONTAINER_IDENTIFIER` value through their
build configuration only after configuring the matching Apple capability and
development container outside this repository. Blank or unresolved `$(...)`
values intentionally report **Not configured**; the app never guesses a
container or calls `CKContainer.default()`.

## Privacy Policy URL configuration

App Store metadata and the in-app policy route require an operator-owned
Privacy Policy URL. Supply it only through the app-target build setting
`ROOMSCANSTUDIO_PRIVACY_POLICY_URL`; `Info.plist` substitutes that value into
`RoomScanStudioPrivacyPolicyURL`. The committed Debug and Release values are
blank. The app accepts only an absolute HTTPS URL with a nonempty host and no
credentials, fragment, control characters, or unresolved build-setting token.
Otherwise Settings and privacy shows **Privacy Policy not configured for this
build** and does not render a link. Do not add a guessed URL to this repository.
