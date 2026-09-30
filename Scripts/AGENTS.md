# Verification tooling

Applies to this tree; inherit the root guide. These Python scripts are evidence
oracles, not application runtime or deployment tools.

## Commands

From the repository root:

```sh
python3 -B -m unittest discover -s Scripts -p 'test_*.py'
python3 -B Scripts/select_simulators.py --self-test
python3 -B Scripts/verify_xcode_scaffold.py
python3 -B Scripts/verify_slice4_static_controls.py
```

Focused example from the hosted command plan:
`python3 -B -m unittest Scripts/test_verify_slice4_hosted.py Scripts/test_verify_slice4_static_controls.py Scripts/test_inspect_ios_artifact.py Scripts/test_slice4_ci_contract.py`.

## Oracle rules

- Use the standard library and `Path(__file__).resolve()`-derived repository
  roots. Match existing bounded subprocess/error handling and private evidence
  writes. Always run Python with `-B`; caches fail the structural gate.
- Simulator selection must derive installed iPhone/iPad destinations from
  `simctl` JSON/type metadata, not hardcoded models, runtimes or historic UUIDs.
- Negative self-tests use temporary roots/in-memory source mutations. A
  detector must reach the unsafe positive control and spare the safe control.
- Fail closed on missing/raw/stale evidence. `COLLECTED`, `INCOMPLETE`, a skipped
  check, or a scoped scanner pass is not terminal whole-slice acceptance.
- Do not fabricate logs, screenshot reviews, attachment hashes, test counts or
  freshness. Changing count floors or source inventories needs actual contract/
  coverage review and negative tests, not accommodation of failing runs.
- Keep compiled-app inspection distinct from source scans. Historical Slice 5
  exclusions differ from current Slice 6: use `inspect_slice6_ios_artifact.py`
  for the current app; it retains Slice 4/5 requirements.
- Long umbrella/finalization sequences belong in
  `../.factory/skills/roomscan-slice-acceptance/SKILL.md`, not this file.
