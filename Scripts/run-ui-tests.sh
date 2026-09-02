#!/bin/bash
#
# Runs the test plan on both chromes.
#
# The UI suite is chrome-agnostic by design (see TrawlUITests/TrawlChrome.swift): the
# same tests navigate a tab bar on iPhone and a split-view sidebar on iPad. That is
# only worth anything if both are actually run, so this runs both and reports each.
#
# Sequentially, and not by accident: concurrent simulator runs fake crashes and leave
# result bundles unfinalized, which costs more time than it saves.
#
# Usage:
#   Scripts/run-ui-tests.sh                       # both destinations, whole plan
#   Scripts/run-ui-tests.sh NavigationSmokeWalkUITests   # both, one suite
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

IPHONE="${TRAWL_IPHONE_SIM:-iPhone 17 Pro}"
IPAD="${TRAWL_IPAD_SIM:-iPad Pro 13-inch (M5)}"
DERIVED="${TRAWL_DERIVED_DATA:-/tmp/trawl-ci-dd}"
RESULTS="${TRAWL_RESULTS_DIR:-/tmp/trawl-ci-results}"

SUITE="${1:-}"
ONLY=()
[ -n "$SUITE" ] && ONLY=(-only-testing:"TrawlUITests/$SUITE")

mkdir -p "$RESULTS"
failures=0

run() {
    local name="$1" device="$2"
    local bundle="$RESULTS/$name.xcresult"
    local log="$RESULTS/$name.log"
    rm -rf "$bundle"

    echo "==> $name: $device"
    xcodebuild -project Trawl.xcodeproj -scheme Trawl \
        -destination "platform=iOS Simulator,name=$device,OS=latest" \
        -derivedDataPath "$DERIVED" \
        -resultBundlePath "$bundle" \
        "${ONLY[@]}" \
        test > "$log" 2>&1
    local status=$?

    # The "Executed N tests" line, not the exit code: a plan whose -only-testing
    # filter matches nothing still exits 0 and prints TEST SUCCEEDED, so a green run
    # that executed zero tests has to be caught here rather than believed.
    local executed
    executed=$(grep -oE "Executed [0-9]+ test" "$log" | tail -1)
    echo "    ${executed:-Executed 0 tests} (exit $status)"
    grep -E "^.*: error:|XCTAssertTrue failed" "$log" | head -20

    if [ $status -ne 0 ] || [ -z "$executed" ] || [ "$executed" = "Executed 0 test" ]; then
        failures=$((failures + 1))
        echo "    FAILED - full log: $log"
    fi
}

run "iphone" "$IPHONE"
run "ipad" "$IPAD"

echo
if [ $failures -eq 0 ]; then
    echo "Both chromes passed."
else
    echo "$failures of 2 chromes failed."
fi
exit $failures
