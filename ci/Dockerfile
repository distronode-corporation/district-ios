# The Linux toolchain for district-ios: Swift, SwiftLint and SwiftFormat.
#
# ⛔ THIS TOOLCHAIN BUILDS AND TESTS Packages/DistrictCore, WHICH IS THE WHOLE
# LINUX-FIRST ARCHITECTURE. Everything that does not need Xcode runs on Linux;
# macOS is needed only for the app build, its simulator tests and the release.
# The `verify` job in .github/workflows/ci.yml runs the same swift image as its
# container and installs the same two tools itself, so this file is that
# environment as an image, for running the Linux checks outside CI.
#
# ⚠️ THE BASE IS PINNED BY TAG *AND* DIGEST. `6.2` is a moving tag and even
# `6.2.4` is rebuilt when its Ubuntu base gets a security update; the digest
# below is what `swift:6.2.4` resolved to when it was pinned. Bumping it is a
# deliberate, reviewable diff, in this file and in the workflow's `container:`.
#
# ⚠️ 6.2.4, NOT 6.3, DELIBERATELY. The Linux toolchain is paired with the
# Xcode the workflow's `app` job selects, which ships Swift 6.2. A Linux
# toolchain ahead of the Xcode one compiles code the app target then rejects,
# and the failure surfaces in the slower macOS job instead of here. Move both
# together, or neither.
FROM swift:6.2.4@sha256:29b983751c605c2d3102d2ab93438c6e0cadf110d9d2aa6e929b6dec9dcb7cbc

# ── SwiftLint / SwiftFormat ──────────────────────────────────────────────────
# ⚠️ OFFICIAL PREBUILT LINUX BINARIES, NOT `swift build` FROM SOURCE. Building
# SwiftLint from source on a runner takes ~10 minutes and pulls in
# SwiftSyntax — a compile cost paid on every image rebuild for a tool whose
# maintainers publish a Linux binary per release. The versions AND their
# SHA-256 sums are pinned; a checksum here is not ceremony, it is the only
# thing that distinguishes the real archive from a redirect page or a
# substituted asset (an unredirected curl can produce a small HTML page instead
# of the zip, and exit 0).
ARG SWIFTLINT_VERSION=0.65.1
ARG SWIFTLINT_SHA256=caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d
ARG SWIFTFORMAT_VERSION=0.63.0
ARG SWIFTFORMAT_SHA256=b4a3cbb8c852a0baaf9adf853e221ff1dabf921a3d8957a602e0bda3af8470f1

# ⚠️ THE SAME VERSIONS AND SHA-256 SUMS ARE IN .github/workflows/ci.yml, which
# installs both tools with the same pins. Move each version and its sum together,
# here and there, in the same commit, or CI and this image lint differently.

RUN set -eux; \
    apt-get update; \
    # ⚠️ python3 IS A REQUIREMENT, NOT A CONVENIENCE. ci/coverage-gate.sh parses
    # llvm-cov's JSON export with it and asserts its presence rather than
    # assuming it — the stock swift image does not guarantee it, and a missing
    # interpreter otherwise surfaces only as `command not found` when the job
    # first runs in the image.
    # ⚠️ libxml2 is for SwiftLint, not for anything of ours — see the ⛔ below.
    apt-get install -y --no-install-recommends \
      ca-certificates curl unzip git python3 libxml2; \
    rm -rf /var/lib/apt/lists/*; \
    \
    cd /tmp; \
    curl -fsSL -o swiftlint.zip \
      "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_amd64.zip"; \
    echo "${SWIFTLINT_SHA256}  swiftlint.zip" | sha256sum -c -; \
    unzip -q swiftlint.zip -d /tmp/swiftlint-extract; \
    # ⛔ THE DYNAMIC `swiftlint`, NOT THE `swiftlint-static` SHIPPED BESIDE IT,
    # AND THE DIFFERENCE IS A SILENTLY SMALLER GATE. The static build has
    # SourceKit compiled out, so it prints
    #   "warning: Skipping enabled rule 'statement_position' because it requires
    #    SourceKit and SourceKit access is prohibited"
    # and then reports "0 violations" — a rule that stopped running, inside a
    # green result. The dynamic build loads sourcekitd from the Swift toolchain
    # already in this image and runs the full rule set with no such warning.
    # Both behaviours verified in this exact image.
    # ⚠️ IT IS WHY `libxml2` IS INSTALLED ABOVE. Without it the dynamic binary
    # dies at startup with "error while loading shared libraries:
    # libxml2.so.2" — a runtime failure in every verify job that reads as
    # "swiftlint is broken" rather than as a missing package.
    install -m 0755 /tmp/swiftlint-extract/swiftlint /usr/local/bin/swiftlint; \
    rm -rf swiftlint.zip /tmp/swiftlint-extract; \
    \
    curl -fsSL -o swiftformat.zip \
      "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux.zip"; \
    echo "${SWIFTFORMAT_SHA256}  swiftformat.zip" | sha256sum -c -; \
    unzip -q swiftformat.zip -d /tmp/swiftformat-extract; \
    install -m 0755 /tmp/swiftformat-extract/swiftformat_linux /usr/local/bin/swiftformat; \
    rm -rf swiftformat.zip /tmp/swiftformat-extract; \
    \
    # Prove the toolchain rather than trusting the exit codes above. A binary
    # that unpacked but cannot run (wrong Swift runtime, wrong arch) would
    # otherwise fail in every later run with an error about the lint step
    # rather than about this build.
    swift --version; \
    swiftlint version; \
    swiftformat --version; \
    python3 --version; \
    llvm-cov --version | head -1

# ⚠️ No SwiftPM cache warming and no `swift build` of anything here. The package
# has one external dependency, apple/swift-crypto (pinned `exact:`, with
# swift-asn1 behind it, both recorded in the committed Package.resolved). It is
# small, the workflow caches `.build` keyed on that file, and baking a .build
# directory in would be invalidated by the first source change anyway.

WORKDIR /builds
