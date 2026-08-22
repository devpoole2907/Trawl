#!/usr/bin/env python3
"""Print the UDID of the best available iPhone simulator.

CI runners do not all carry the same runtimes, so pinning an exact device name
in the workflow makes the job fail on an image bump. This prefers the device
the project documents (iPhone 17 Pro), falls back to any iPhone, and always
picks the newest iOS runtime available.
"""
import json
import subprocess
import sys

PREFERRED = "iPhone 17 Pro"


def runtime_sort_key(identifier: str) -> list[int]:
    # "com.apple.CoreSimulator.SimRuntime.iOS-26-4" -> [26, 4]
    tail = identifier.rsplit("iOS-", 1)[-1]
    return [int(part) if part.isdigit() else 0 for part in tail.split("-")]


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
    devices = json.loads(raw)["devices"]

    runtimes = sorted(
        (rt for rt in devices if "iOS" in rt), key=runtime_sort_key, reverse=True
    )

    for runtime in runtimes:
        iphones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
        if not iphones:
            continue
        exact = [d for d in iphones if d["name"] == PREFERRED]
        chosen = (exact or iphones)[0]
        print(chosen["udid"])
        print(f"{chosen['name']} on {runtime}", file=sys.stderr)
        return 0

    print("error: no available iPhone simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
