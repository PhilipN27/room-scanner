#!/usr/bin/env python3
"""Exercise deterministic positive controls for the Slice 4 static guards."""

from __future__ import annotations

import json
from pathlib import Path
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import verify_slice4_hosted
from Scripts import verify_xcode_scaffold


def run_controls() -> dict[str, str]:
    sources = verify_xcode_scaffold.read_guest_production_sources()
    baseline_errors = verify_xcode_scaffold.guest_hosted_boundary_errors(sources)
    if baseline_errors:
        raise RuntimeError(
            f"guest-network baseline has {len(baseline_errors)} forbidden boundary finding(s)"
        )
    app_environment = (
        verify_xcode_scaffold.ROOT / "RoomScanStudio" / "App" / "AppEnvironment.swift"
    )
    if app_environment not in sources:
        raise RuntimeError("guest static positive control lacks AppEnvironment.swift")
    injected_sources = dict(sources)
    injected_sources[app_environment] += (
        '\nprivate let slice4InjectedHostedRequest = URLSession.shared.dataTask('
        'with: URL(string: "https://offline-guard.invalid")!)\n'
    )
    errors = verify_xcode_scaffold.guest_hosted_boundary_errors(injected_sources)
    if not any("Foundation HTTP client outside the exact audited transport" in error for error in errors):
        raise RuntimeError("guest-network scanner did not detect its injected URLSession positive control")
    verify_slice4_hosted.run_secret_scanner_positive_control()
    return {"guestNetworkScanner": "PASS", "structuredSecretScanner": "PASS"}


def main() -> int:
    print(json.dumps(run_controls(), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
