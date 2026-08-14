#!/usr/bin/env python3
"""Select one available iPhone and iPad from the latest iOS simulator runtime.

The parser is deliberately independent from ``xcrun`` so its selection policy
can be exercised on non-macOS hosts with a synthetic ``simctl -j`` payload.
It never bakes a device model or runtime identifier into CI.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


class SimulatorSelectionError(ValueError):
    """Raised when an iOS runtime does not offer both required device families."""


def _runtime_version(identifier: str) -> tuple[int, int, int] | None:
    """Return an iOS runtime version from a simctl runtime identifier."""

    match = re.search(r"(?:^|\.)iOS[-.]([0-9]+)(?:[-.]([0-9]+))?(?:[-.]([0-9]+))?$", identifier)
    if match is None:
        return None
    return tuple(int(part or 0) for part in match.groups())


def _is_available(device: dict[str, Any]) -> bool:
    if device.get("isAvailable") is False:
        return False
    availability = str(device.get("availability", "")).lower()
    return "unavailable" not in availability


def _device_family(device: dict[str, Any]) -> str | None:
    """Classify custom-named devices from stable simctl type metadata first."""
    device_type = str(device.get("deviceTypeIdentifier", ""))
    name = str(device.get("name", ""))
    if ".SimDeviceType.iPhone-" in device_type or name.startswith("iPhone"):
        return "iphone"
    if ".SimDeviceType.iPad-" in device_type or name.startswith("iPad"):
        return "ipad"
    return None


def select_latest_ios_destinations(payload: dict[str, Any]) -> dict[str, str]:
    """Return deterministic XCTest destination strings from a simctl JSON payload."""

    devices_by_runtime = payload.get("devices")
    if not isinstance(devices_by_runtime, dict):
        raise SimulatorSelectionError("simctl JSON has no devices dictionary")

    runtimes: list[tuple[tuple[int, int, int], str, list[dict[str, Any]]]] = []
    for runtime_identifier, raw_devices in devices_by_runtime.items():
        version = _runtime_version(str(runtime_identifier))
        if version is None or not isinstance(raw_devices, list):
            continue
        devices = [item for item in raw_devices if isinstance(item, dict) and _is_available(item)]
        runtimes.append((version, str(runtime_identifier), devices))

    for _, runtime_identifier, devices in sorted(runtimes, reverse=True):
        ordered = sorted(
            devices,
            key=lambda item: (str(item.get("name", "")), str(item.get("udid", ""))),
        )
        iphone = next((item for item in ordered if _device_family(item) == "iphone"), None)
        ipad = next((item for item in ordered if _device_family(item) == "ipad"), None)
        if iphone is None or ipad is None:
            continue
        iphone_udid = iphone.get("udid")
        ipad_udid = ipad.get("udid")
        if not isinstance(iphone_udid, str) or not iphone_udid:
            raise SimulatorSelectionError(f"latest eligible runtime {runtime_identifier} has no iPhone UUID")
        if not isinstance(ipad_udid, str) or not ipad_udid:
            raise SimulatorSelectionError(f"latest eligible runtime {runtime_identifier} has no iPad UUID")
        return {
            "iphone_destination": f"platform=iOS Simulator,id={iphone_udid}",
            "ipad_destination": f"platform=iOS Simulator,id={ipad_udid}",
            "runtime_identifier": runtime_identifier,
        }

    raise SimulatorSelectionError(
        "no available iOS runtime contains both an iPhone and an iPad simulator"
    )


def _self_test() -> None:
    synthetic = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
                {"name": "iPhone 14", "udid": "old-phone", "isAvailable": True},
                {"name": "iPad (10th generation)", "udid": "old-pad", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
                {"name": "iPhone 16", "udid": "unavailable-phone", "isAvailable": False},
                {"name": "iPhone 15", "udid": "new-phone", "isAvailable": True},
                {
                    "name": "RoomScanStudio Custom Tablet",
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB",
                    "udid": "new-pad",
                    "isAvailable": True,
                },
            ],
        }
    }
    result = select_latest_ios_destinations(synthetic)
    assert result["runtime_identifier"].endswith("iOS-18-2")
    assert result["iphone_destination"].endswith("new-phone")
    assert result["ipad_destination"].endswith("new-pad")
    try:
        select_latest_ios_destinations({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-2": []}})
    except SimulatorSelectionError:
        pass
    else:
        raise AssertionError("selector accepted a runtime without both device families")


def _load_payload(input_path: str | None) -> dict[str, Any]:
    if input_path:
        loaded = json.loads(Path(input_path).read_text(encoding="utf-8"))
    else:
        raw = subprocess.check_output(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            text=True,
        )
        loaded = json.loads(raw)
    if not isinstance(loaded, dict):
        raise SimulatorSelectionError("simctl JSON root is not an object")
    return loaded


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", help="synthetic or captured simctl JSON for a host-side check")
    parser.add_argument("--github-output", help="write GitHub Actions outputs to this file")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        _self_test()
        print("simulator selector self-test passed")
        return 0

    destinations = select_latest_ios_destinations(_load_payload(args.input))
    lines = [
        f"iphone_destination={destinations['iphone_destination']}",
        f"ipad_destination={destinations['ipad_destination']}",
        f"runtime_identifier={destinations['runtime_identifier']}",
    ]
    output_path = args.github_output or os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with Path(output_path).open("a", encoding="utf-8", newline="\n") as output:
            output.write("\n".join(lines) + "\n")
    print("selected " + destinations["runtime_identifier"])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SimulatorSelectionError as error:
        print(f"simulator selection failed: {error}", file=sys.stderr)
        raise SystemExit(2)
