#!/usr/bin/env bash
#
# Build the app UNSIGNED, in Release, twice from clean, and fail unless every file in
# the two products is byte for byte the same.
#
#     ci/repeatable-build.sh <scheme> <destination> <product>
#     ci/repeatable-build.sh DistrictAI 'generic/platform=iOS' Release-iphoneos/DistrictAI.app
#
# Each build deletes DerivedData first, so the second cannot reuse the first one's
# outputs. Both use the same DerivedData path and the same resolved SourcePackages, so
# paths embedded in the binaries are the same too. CODE_SIGNING_ALLOWED=NO: no
# signature to strip before comparing, and no Apple account needed.
#
# Expected differences: none. Every file is compared; nothing is skipped.
#
# ⛔ SWIFT_DETERMINISTIC_HASHING=1 IS PART OF THE RECIPE. Xcode's App Intents metadata
# extractor (appintentsmetadataprocessor, a Swift tool) writes
# Metadata.appintents/version.json from a Swift Dictionary, and a Dictionary's order
# follows a hash seed that is random per process unless this variable is set. Without
# it the file's two keys came out in either order, so two clean builds differed in
# DistrictAIWatch.app/Metadata.appintents/version.json about half the time. The
# variable changes no compiler output; it only fixes the seed of the Swift tools the
# build runs.
#
# On a difference it prints each differing file and keeps both products under
# $RUNNER_TEMP/repeatable (or /tmp/repeatable) for the job to upload.
set -euo pipefail

scheme=$1
destination=$2
product=$3
OUT=${RUNNER_TEMP:-/tmp}/repeatable
export SWIFT_DETERMINISTIC_HASHING=1
rm -rf "$OUT"
mkdir -p "$OUT"

for n in 1 2; do
  echo "== build $n"
  rm -rf DerivedData
  xcodebuild build \
    -project DistrictAI.xcodeproj \
    -scheme "$scheme" \
    -configuration Release \
    -destination "$destination" \
    -derivedDataPath DerivedData \
    -clonedSourcePackagesDirPath SourcePackages \
    CODE_SIGNING_ALLOWED=NO > "$OUT/build-$n.log" 2>&1 || {
      tail -n 100 "$OUT/build-$n.log"
      exit 1
    }
  mkdir -p "$OUT/$n"
  # ditto keeps symlinks inside bundles as symlinks.
  ditto "DerivedData/Build/Products/$product" "$OUT/$n/$(basename "$product")"
  # Regular files by content, plus every symbolic link by its literal target (not
  # followed), so an added, removed or retargeted link (e.g. Versions/Current) differs too.
  (cd "$OUT/$n" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$OUT/$n.sha256"
  (cd "$OUT/$n" && find . -type l -print0 | sort -z | while IFS= read -r -d '' l; do
    printf 'link  %s -> %s\n' "$l" "$(readlink "$l")"
  done) >> "$OUT/$n.sha256"
  echo "$(wc -l < "$OUT/$n.sha256" | tr -d ' ') files in build $n"
done

if diff -u "$OUT/1.sha256" "$OUT/2.sha256" > "$OUT/sha256.diff"; then
  echo "PASS: both unsigned builds of $(basename "$product") are byte for byte identical"
  exit 0
fi

echo "FAIL: the two builds differ in these files:"
grep -E '^[-+]([0-9a-f]{64}|link) ' "$OUT/sha256.diff" | sed -E 's/^[-+]([0-9a-f]{64}|link)  //; s/ -> .*$//' | sort -u | tee "$OUT/differing.txt"
exit 1
