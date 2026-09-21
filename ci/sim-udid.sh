#!/usr/bin/env bash
#
# Choose a simulator to run the XCTest bundles on, and write its udid to
# simulator-udid.txt in the current directory.
#
#   ci/sim-udid.sh iPhone
#   ci/sim-udid.sh iPad
#
# Then: xcodebuild test-without-building ... -destination "id=$(cat simulator-udid.txt)"
#
# ⛔ THE DESTINATION IS DISCOVERED, NOT NAMED. A device name ("name=iPhone 17") ties
# CI to whatever the runner image ships and fails with "Unable to find a destination"
# when the image is rotated. Each filter below exists because a real `simctl list -j`
# needed it:
#   * the runtime KEY must be an iOS one: images carry watchOS, tvOS and visionOS keys
#     beside it, and JSON key order is not a promise;
#   * the device type must be the requested family: an iPhone-only build installs and
#     runs on an iPad, so an unfiltered pick can go green having tested the wrong form
#     factor;
#   * `isAvailable` stays checked, because the `available` subcommand still lists
#     half-installed runtimes on some Xcodes.
#
# ⚠️ NEWEST iOS RUNTIME THAT IS NOT NEWER THAN THE ACTIVE XCODE ITSELF. Runner images
# install several Xcodes side by side with the runtimes of each, so the newest runtime
# on the machine can belong to a newer Xcode than the one selected. The cap is the
# Xcode version, not its simulator SDK version: Xcode 26.3 carries the 26.2 SDK and
# runs an iOS 26.3 runtime, so an SDK cap would refuse a runtime that works.
#
# The full list is printed so a rotation that changes the device is attributable from
# the job log. The JSON is parsed with python3, which Xcode's command line tools provide.
set -euo pipefail

family="${1:-}"
case "$family" in
  iPhone | iPad) ;;
  *)
    echo "usage: ci/sim-udid.sh iPhone|iPad" >&2
    exit 64
    ;;
esac

# ⛔ NOT `xcodebuild -version | head -n 1`. Under `pipefail`, `head` closes the pipe after
# the first line and xcodebuild, writing its second line unbuffered on a CI runner
# (NSUnbufferedIO), aborts on the broken pipe with exit 134. Read all of it, keep line one.
xcode_all="$(xcodebuild -version)"
xcode_line="${xcode_all%%$'\n'*}"
xcode_version="${xcode_line#Xcode }"
echo "--- active Xcode"
echo "$xcode_line (iphonesimulator SDK $(xcrun --sdk iphonesimulator --show-sdk-version))"

echo "--- available simulators"
xcrun simctl list devices available

udid="$(xcrun simctl list -j devices available | FAMILY="$family" XCODE_VERSION="$xcode_version" python3 -c '
import json
import os
import sys

family = os.environ["FAMILY"]
prefix = "SimRuntime.iOS-"
wanted = "SimDeviceType." + family + "-"


def parse(text, separator):
    try:
        return tuple(int(part) for part in text.split(separator))
    except ValueError:
        return None


ceiling = parse(os.environ["XCODE_VERSION"], ".")
if ceiling is None:
    sys.exit("cannot parse the Xcode version " + repr(os.environ["XCODE_VERSION"]))

devices = json.load(sys.stdin)["devices"]
runtimes = []
for key in devices:
    if prefix in key:
        version = parse(key.split(prefix, 1)[1], "-")
        if version is not None and version <= ceiling:
            runtimes.append((version, key))

for _, runtime in sorted(runtimes, reverse=True):
    for dev in devices[runtime]:
        if dev.get("isAvailable") and wanted in dev.get("deviceTypeIdentifier", ""):
            print("chose " + dev["name"] + " on " + runtime, file=sys.stderr)
            print(dev["udid"])
            raise SystemExit(0)
raise SystemExit(1)
')" || udid=""

if [ -z "$udid" ]; then
  echo "FATAL - no available $family simulator on an iOS runtime at or below the" >&2
  echo "active Xcode ($xcode_version), so there is no destination to run an XCTest" >&2
  echo "bundle on. See the list above." >&2
  exit 1
fi

echo "destination udid - $udid"
echo "$udid" >simulator-udid.txt
