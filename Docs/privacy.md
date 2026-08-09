# Privacy and permissions

RoomScanStudio requests camera access only after the user selects **Prepare
capture**, and when-in-use location access only after **Request GPS**. A denied
location request never blocks manual location or local Save. The deterministic
fixture makes no camera, AR, or GPS claim.

The in-app Privacy Policy route reads the operator-owned
`ROOMSCANSTUDIO_PRIVACY_POLICY_URL` build setting through
`RoomScanStudioPrivacyPolicyURL` in `Info.plist`. It accepts only a strict
absolute HTTPS URL without credentials, fragments, control characters, or an
unresolved build token. A blank or invalid value visibly says **Privacy Policy
not configured for this build** instead of creating a guessed link.

`PrivacyInfo.xcprivacy` declares tracking false, no tracking domains, and the
required-reason API categories File Timestamp (`C617.1`) and User Defaults
(`CA92.1`). The current source assessment is unsigned-off and keeps its
collected-data list empty: there is no public/shared database, server/operator
access, analytics, or sharing path. Private backup is disabled by default and
an upload requires separate explicit opt-in and Back up actions. This is not
an Apple certification, a legal conclusion, or a substitute for release-owner
review.

Before distribution, the Account Holder must choose and record either the
empty-list rationale for this exact private-only design or a four-category
disclosure for Precise Location, Photos or Videos, Environment Scanning, and
Other User Content, including each category's Linked determination. The owner
must independently validate the App Store Connect privacy answers, Privacy
Policy metadata URL, in-app link, and built privacy report. Reassess those
categories if public or shared CloudKit, server/operator access, analytics, or
sharing is added. This repository does not assert legal approval.

Primary Apple references: [privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests) and [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).
