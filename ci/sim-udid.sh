#!/usr/bin/env bash
#
# Choose a simulator to run the XCTest bundles on, and write its udid to
# simulator-udid.txt in the current directory.
#
#   ci/sim-udid.sh iPhone
#   ci/sim-udid.sh iPad
#   ci/sim-udid.sh Watch    (writes watch-simulator-udid.txt instead)
#
# Then: xcodebuild test-without-building ... -destination "id=$(cat simulator-udid.txt)"
#
# ⚠️ `Watch` PICKS AN APPLE WATCH ON A watchOS RUNTIME, for the watch app's own unit tests
# (the `DistrictAIWatch` scheme). Its runtime is capped by the active Xcode's watchOS
# SIMULATOR SDK rather than by the Xcode version: watchOS numbers do not follow Xcode's
# (Xcode 26.3 carries watchOS 26.2), and a newer Xcode installed beside it brings a newer
# watchOS runtime the selected Xcode cannot run.
#
# ⛔ THE DESTINATION IS DISCOVERED, NOT NAMED. A device name ("name=iPhone 17") ties
# CI to whatever the runner image ships and fails with "Unable to find a destination"
# when the image is rotated. Each filter below exists because a real `simctl list -j`
# needed it:
#   * the runtime KEY must be the requested platform's: images carry iOS, watchOS, tvOS
#     and visionOS keys side by side, and JSON key order is not a promise;
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
  iPhone | iPad)
    runtime_prefix="SimRuntime.iOS-"
    device_prefix="SimDeviceType.$family-"
    sdk="iphonesimulator"
    out="simulator-udid.txt"
    ;;
  Watch)
    runtime_prefix="SimRuntime.watchOS-"
    device_prefix="SimDeviceType.Apple-Watch-"
    sdk="watchsimulator"
    out="watch-simulator-udid.txt"
    ;;
  *)
    echo "usage: ci/sim-udid.sh iPhone|iPad|Watch" >&2
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
sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
echo "$xcode_line ($sdk SDK $sdk_version)"
# iOS runtimes are capped by the Xcode version (see above); watchOS ones by the SDK.
if [ "$family" = "Watch" ]; then
  ceiling="$sdk_version"
else
  ceiling="$xcode_version"
fi

echo "--- available simulators"
xcrun simctl list devices available

udid="$(xcrun simctl list -j devices available | RUNTIME_PREFIX="$runtime_prefix" DEVICE_PREFIX="$device_prefix" CEILING="$ceiling" python3 -c '
import json
import os
import sys

prefix = os.environ["RUNTIME_PREFIX"]
wanted = os.environ["DEVICE_PREFIX"]


def parse(text, separator):
    try:
        return tuple(int(part) for part in text.split(separator))
    except ValueError:
        return None


ceiling = parse(os.environ["CEILING"], ".")
if ceiling is None:
    sys.exit("cannot parse the version ceiling " + repr(os.environ["CEILING"]))

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
  echo "FATAL - no available $family simulator on a runtime at or below $ceiling" >&2
  echo "(the active Xcode is $xcode_version), so there is no destination to run an" >&2
  echo "XCTest bundle on. See the list above." >&2
  exit 1
fi

echo "destination udid - $udid"
echo "$udid" >"$out"
