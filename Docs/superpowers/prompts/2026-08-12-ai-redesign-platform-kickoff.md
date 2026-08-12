# Fresh-Session Implementation Prompt

Copy the prompt below into a fresh Codex session opened at the RoomScanStudio
repository root.

---

Implement the approved RoomScanStudio AI Redesign Platform plan. Use **Ultra**
effort for the overall multi-slice program and **Max** for focused slices. Work
carefully and persist until the current authorized slice is genuinely complete,
but do not claim the entire program is complete from one slice.

Before changing anything:

1. Read all applicable `AGENTS.md` files and
   `.agents/memory/MEMORY.md` if present, then only relevant memory topics.
2. Read these authoritative planning files completely:
   - `Docs/superpowers/specs/2026-08-12-ai-redesign-platform-design.md`
   - `Docs/superpowers/plans/2026-08-12-ai-redesign-platform.md`
   - `ROOMSCANSTUDIO_MASTER_BUILD_PLAN.md`
   - `Docs/architecture.md`
   - `Docs/privacy.md`
   - `Docs/export-format.md`
   - `Docs/icloud-setup.md`
   - `Docs/real-device-test-plan.md`
   - `Docs/release-checklist.md`
3. Inspect the repository, current branch, working tree, tests, installed Xcode
   SDK, and existing package/export/backup/capture/viewer boundaries. Treat any
   pre-existing uncommitted changes as user-owned and do not overwrite or stage
   them.
4. Treat the 2026-08-12 approved design as controlling where it deliberately
   supersedes the legacy exclusions. Do not reopen confirmed product decisions.

Start with **Slice 0: Plan revision, feasibility, and service decision**. Enter
plan mode before implementation and state the outcome, scope, non-goals,
ordered tasks, ownership boundaries, rollback point, and exact proof. Do not
select or install a backend merely from familiarity: produce an evidence-backed
ADR comparing viable U.S.-region options against conditional writes, tenant
isolation, signed object access, encryption, deletion lifecycle, auditability,
identity, billing, local development, and measured cost. Browse official
primary documentation for volatile service/API facts.

Then implement slices in the documented dependency order. For each slice:

- use the repository's established planning and testing conventions;
- make the smallest architecture-safe change;
- use meaningful red-green-refactor tests for new behavior and guards;
- temporarily neutralize new correctness/security guards when safe to prove
  their focused tests need them, then restore and rerun;
- preserve immutable local package truth and backward compatibility;
- keep guest scan/save/view/edit/AI export/import fully offline and account-free;
- keep private CloudKit backup separate from professional hosted sync;
- never silently merge sync conflicts or upload raw capture bundles by default;
- build public snapshots from explicit allowlists;
- verify Apple capabilities against the installed SDK and require real-device
  evidence for RoomPlan, ARKit/LiDAR, Face ID, and Share Sheet claims;
- close UI work with desktop/mobile or iPhone/iPad screenshots as appropriate;
- update verification logs and release documentation with actual evidence and
  explicit unverified gates;
- run focused tests, then the relevant broader test/build matrix before claiming
  completion.

Stop and ask only for a genuinely open requirement, new authority, vendor or
billing decision that materially changes the approved architecture, or an
external credential/configuration blocker. Do not ask me for facts available in
the repository or official documentation.

At every handoff report: what changed, why, exact commands and results, device
or service behaviors still unverified, risks/rollback state, and the next slice.
Do not commit, push, open a PR, provision production infrastructure, purchase a
service, or change external accounts unless I explicitly authorize that action
in the fresh session.

---
