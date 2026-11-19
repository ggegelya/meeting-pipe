#!/usr/bin/env bash
# The Swift toolchain floor install.sh checks before `swift build` (DIST5).
# Sourced, not run.
#
# daemon/Package.swift says tools 5.9, but the pinned FluidAudio declares
# `swift-tools-version: 6.0`, so a 5.x toolchain fails at package resolution
# with a SwiftPM error that names neither Swift 6 nor the fix. The text
# predicate is split from the `swift --version` call so scripts/test-relaunch.sh
# can pin it on canned output.

SWIFT_TOOLS_MIN_MAJOR=6
SWIFT_TOOLS_MIN_MINOR=0

# swift_version_from_output <swift --version output>: "MAJOR.MINOR", or nothing.
# Reads `Apple Swift version 6.0.3 (...)` and `Swift version 5.10 (...)`.
swift_version_from_output() {
    printf '%s\n' "$1" | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1.\2/p' | head -1
}

# swift_version_ok <swift --version output>: exit 0 at 6.0 or newer.
swift_version_ok() {
    local v major minor
    v="$(swift_version_from_output "$1")"
    [[ -n "$v" ]] || return 1
    major="${v%%.*}"; minor="${v#*.}"
    (( major > SWIFT_TOOLS_MIN_MAJOR )) && return 0
    (( major == SWIFT_TOOLS_MIN_MAJOR && minor >= SWIFT_TOOLS_MIN_MINOR ))
}
