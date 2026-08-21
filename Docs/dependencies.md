# Dependencies

The root Swift package has no third-party dependency. `RoomScanCore` uses
Foundation plus the standard `simd` module for portable vector math, and
remains portable across its declared macOS 13/iOS 17 targets. It does not import
Apple UI, capture, cloud, or persistence frameworks. The iOS app uses Apple
frameworks at isolated boundaries: SwiftUI, SwiftData local indexing,
RoomPlan/ARKit capture, RealityKit non-AR viewing, UIKit export/share, and
CloudKit private backup transport. Slice 3 additionally uses `ImageIO` and
`CoreGraphics` for bounded image decode/re-encode and derivatives, `Vision` for
advisory sensitive-content analysis, and `UniformTypeIdentifiers` for the
JPEG/PNG/ZIP document-picker allowlist. These are local Apple-framework
boundaries; they are not provider or hosted dependencies.

The iOS app target has one intentionally pinned remote Swift package:
[`MetalSplatter`](https://github.com/scier/MetalSplatter) at revision
`2b965de1934de38dda1c71cf90bf798aa948a14c`. Its committed Xcode workspace
resolution also pins its current transitive packages: `spz-swift` 2.1.0 at
`e2410c91bceba2539c11157ad92e488ef6e16416` and
`swift-argument-parser` 1.8.2 at
`6a52f3251125d74daf04fcbd5e6f08a75d074382`. The structural verifier permits
only that exact MetalSplatter URL and revision and checks those resolved pins;
it does not generally allow remote packages.

The Slice 3 production `AIRedesign` path adds no ZIP library, analytics SDK,
login SDK, provider/model SDK, authentication client, direct HTTP client,
converter, or server dependency. ZIPFoundation was considered earlier but is
not used; deterministic AI Room Package and Concept Set archives reuse the
bounded in-repository classic ZIP32 STORE implementation and strict extractors.
Slice 3 adds no Swift package. The scoped AIRedesign production-source scan
rejects injected network/auth clients, with an in-memory `URLSession` control
proving the detector reaches that boundary. This is not a claim that the entire
app is network-free: the separately scoped, explicit private CloudKit backup
transport remains. Future converters, hosted sync, or provider adapters require
license, offline-scope, privacy, artifact-inspection, and platform proof review
before adoption.

## Slice 4 hosted-service inventory

The optional professional service is a separate Node/TypeScript workspace. The
iOS app and `RoomScanCore` import none of these packages. Versions are exact in
the committed npm lockfiles; transitive packages and integrity hashes remain
authoritative in those lockfiles.

| Package/runtime | Pinned version | License | Purpose and network/privacy boundary |
| --- | --- | --- | --- |
| Node.js | 24.x runtime target; local evidence used 24.15.0 | MIT | Lambda/service runtime and deterministic local tests; not embedded in iOS. |
| TypeScript | service 5.9.3; infrastructure 7.0.2 | Apache-2.0 | Strict compilation/declarations only; no runtime network behavior. |
| `@types/node` | 24.13.3 | MIT | Development-only Node declarations. |
| `pg` | 8.16.3 | MIT | Disposable PostgreSQL 16 integration/runtime-harness client; connects only to the explicitly supplied Unix-socket/TLS database target. Production Lambda uses the RDS Data API port instead of shipping `pg` to iOS. |
| `@aws-sdk/client-cloudtrail` | 3.1113.0 | Apache-2.0 | Infrastructure/operational CloudTrail integration only; no guest/iOS use. |
| `@aws-sdk/client-cloudwatch` | 3.1113.0 | Apache-2.0 | Infrastructure/operational alarm integration only; no guest/iOS use. |
| `aws-cdk-lib` | 2.265.0 | Apache-2.0 | Infrastructure definitions and offline synthesis. Synthesis does not prove deployed AWS behavior. |
| `constructs` | 10.8.1 | Apache-2.0 | CDK construct model. |
| `aws-cdk` | 2.1137.0 | Apache-2.0 | Development-only CDK CLI; deployment is not authorized by Slice 4. |
| `esbuild` | 0.28.2 | MIT | Development-only Lambda asset bundling. |

Provider calls are isolated behind app-owned adapters for Apple, Cognito, SES,
S3, RDS Data API, Stripe, CloudWatch, and CloudTrail. No general AWS, database,
service-role, or provider credential is shipped to iOS or included in public
contracts. Deterministic tests use injected clocks/transports/clients and
offline/dummy infrastructure values. A lockfile or SDK type does not establish
provider correctness, availability, privacy terms, or deployed IAM behavior.

## Update and SBOM policy

- Review direct and transitive license/security changes before every release
  and before changing any locked version. Do not use floating ranges in the
  hosted workspaces.
- Upgrade in a dedicated change with service/database/infrastructure tests,
  mutation controls, offline synth, emitted-artifact inspection, and a fresh
  official-provider behavior review where an API contract changed.
- Perform a live vulnerability/advisory lookup only in an authorized release
  environment; the recorded offline `npm` result is not a current registry or
  ecosystem audit.
- At the 2026-08-19 checkpoint, the top-level verification runner was intended
  to generate the CycloneDX file
  `.artifacts/slice4-hosted/sbom.cdx.json` and the paired artifact manifest.
  Those then-pending paths are historical; the dated reconciliation below
  records the executed `slice4-hosted-final` outputs and digests.

## 2026-08-21 dependency/evidence reconciliation

The accepted local runtime is Node.js **24.15.0**. Under that runtime the
service passed strict typecheck, 277/277 tests and build; the disposable
PostgreSQL package passed its 43-command matrix; and the current offline
infrastructure package passed 104/104 tests plus 17/17 mutations. These results
use the checked-in lockfiles and do not constitute a fresh online advisory,
license-registry or provider-runtime lookup.

The post-IAM-fix synthesized infrastructure template SHA-256 is
`9309d2c294b9672ddc9e83462c658401acb5c5523cefac20b5cfdd7b5b3a7b12`;
its assets-manifest SHA-256 is
`b45dbd74005db34ba2c1c4a4b7f086e04f4043e5a3033edb75b9757a8d013030`.
The fresh hosted verifier emitted CycloneDX 1.6 at
`.artifacts/slice4-hosted-final/sbom.cdx.json`: **148 components** (145
libraries and three lockfiles), SHA-256
`d0c07261c0149dfa63c1a8083a0247ab64de9f28873151bfec3a4ba7312e175e`.
Its current 128-file artifact manifest passed the secret scan and has SHA-256
`42b2679d33b239185d73ed096302bd0e33f319f22361858acd26e6cf1789a878`.
No external dependency service was contacted and no price was researched or
recorded.
