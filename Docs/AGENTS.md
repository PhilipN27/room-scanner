# Documentation and evidence

Applies to this tree; inherit the root guide.

## Sources of truth

- `architecture.md`, `feasibility.md`, `export-format.md`: architectural and
  capture/archive boundaries.
- `contracts/`, `decisions/`: versioned consumer/provider-neutral contracts and
  reviewed decisions. Reconcile code and consumers before changing guarantees.
- `superpowers/plans/`, `superpowers/specs/`: implementation/proof plans, not
  evidence that every planned action happened.
- `evidence/`, `verification-log.md`: dated evidence ledger. Current Slice 6
  status is in `evidence/2026-09-20-ai-redesign-slice-6-closure.md`; older slice
  descriptions/counts remain historical rather than current feature restrictions.
- `setup.md`, `release-checklist.md`, `real-device-test-plan.md`,
  `operations/professional-service-runbook.md`: operator/release gates.

## Writing and verification rules

- Preserve prior checkpoints and append a dated reconciliation with exact
  command, environment, result/count, evidence tier, artifact binding and
  limitations. Do not rewrite historical results to look like new runs.
- Label static, macOS compilation, Simulator, disposable PostgreSQL, synthetic
  browser/offline synth, physical-device and live-provider evidence separately.
  A plan, source comment, or local PASS does not close an external/release gate.
- Keep contracts, safety invariants and link targets consistent with code.
  Do not copy current raw artifacts/customer data/secrets into docs.
- Screenshots/fixture archives are retained evidence/contracts. Do not edit
  images, silently replace bytes, invent reviews or describe generated renders
  as actual XCTest/browser captures.
- Check links and commands against tracked paths and package/scripts. For
  verifier/CI-facing doc changes, run
  `python3 -B -m unittest discover -s Scripts -p 'test_*.py'` and
  `python3 -B Scripts/verify_xcode_scaffold.py` from the repository root.
- Put new reusable long procedures in `.factory/skills/<name>/SKILL.md` with
  `name`/`description` frontmatter and source references. Link the existing
  runbook rather than duplicating live operator procedures in `AGENTS.md`.
