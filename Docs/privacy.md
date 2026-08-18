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
(`CA92.1`). There is no public/shared database, server/operator access,
analytics, or automatic upload. The production Slice 3 `AIRedesign` path adds
no provider SDK, model call, account/authentication client, or direct HTTP
client. This is not a claim that the entire target is network-free: explicit
private CloudKit backup remains separately scoped, disabled by default, and
requires separate opt-in and Back up actions. Slice 3 does add a local,
user-directed outbound path: after reviewing the exact package profile,
selected images and metadata, artifact inventory, warnings, size estimate,
precise-GPS exclusion, and external-provider privacy/account notice, the user
may present the system Share Sheet. The owned temporary archive is retained
only for that activity and cleaned after completion, cancellation, error, or
dismissal fallback in the local flow.

AI-ready structurally excludes raw RGB/depth/confidence/diagnostics, world maps,
and precise GPS. Complete still excludes world maps and precise GPS and may
include available raw evidence only when the exact reviewed package actually
contains it and the user explicitly accepts that raw disclosure. Outbound
JPEG/PNG selections are decoded and re-encoded with non-allowlisted metadata
removed; ambiguous, active, polyglot, mislabeled, or trailing-payload media is
rejected. Sensitive-content analysis is advisory: it can flag possible people,
family photographs, documents, screens, addresses/location disclosure, and
reflective surfaces, but it is not perfect detection or automatic redaction.

Concept images and archives are untrusted local inputs. They are bounded,
validated, decoded/re-encoded, and promoted into separate additive storage
without following external URLs or contacting a network. None of these source
statements is an Apple certification, a legal conclusion, or a substitute for
release-owner review. Local/Simulator completion does not prove which physical
share targets, provider services, or terms a release user will encounter.

Before distribution, the Account Holder must review the data-use effect of the
explicit local Share Sheet and Concept import routes and choose the exact App
Store disclosures, including whether Precise Location, Photos or Videos,
Environment Scanning, or Other User Content applies and each category's Linked
determination. The owner must independently validate the App Store Connect
privacy answers, Privacy Policy metadata URL, in-app link, and built privacy
report. Reassess them if public/shared CloudKit, server/operator access,
analytics, or hosted sharing is added. This repository does not assert legal
approval or that an empty collected-data list remains correct.

Primary Apple references: [privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests) and [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).
