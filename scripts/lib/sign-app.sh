#!/usr/bin/env bash
# Shared app-bundle signing for install.sh and rebuild.sh. Sourced, not run.
#
# One pass: the outer .app, with the stable `com.meetingpipe.daemon`
# identifier. It used to be two: SwiftPM's resource bundles have a `.bundle`
# suffix but no Info.plist, and while they sat in Contents/MacOS codesign took
# them for nested code and refused them ("bundle format unrecognized, invalid,
# or unsuitable"), so each got a minimal Info.plist and its own signature
# first. DIST4 moved them to Contents/Resources (scripts/lib/resource-bundles.sh),
# where the outer signature seals them as plain resources; `codesign --verify
# --deep --strict` passes on that layout (scripts/test-app-relocation.sh checks).
#
# The signing identity comes from `signing_identity` (see dev-cert.sh): the
# self-signed "MeetingPipe Dev" cert when present, else ad-hoc `-`. With the
# cert the app's designated requirement is identity-based
# (`identifier "..." and certificate leaf = H"..."`), which does NOT pin the
# cdhash, so Screen Recording survives a rebuild and is granted just once. The
# ad-hoc fallback pins the cdhash and so still needs a Screen Recording
# re-toggle per rebuild; `--identifier` keeps the (bundle_id, identifier) pair
# stable either way, so Mic / Notifications / Accessibility survive regardless.
#
# This lives in one place so install.sh and rebuild.sh cannot drift again. The
# drift is exactly what once left rebuild.sh trying to codesign the plist-less
# bundles and aborting mid-run (new binary copied, app left unsigned, daemon
# not relaunched).

# shellcheck source=scripts/lib/dev-cert.sh
source "$(dirname "${BASH_SOURCE[0]}")/dev-cert.sh"

# sign_app_with_resources <app_path>
#   Sign the app, sealing its Contents/Resources (resource bundles included).
#   Runs under the caller's `set -e`, so a codesign failure aborts.
sign_app_with_resources() {
    local app="$1"
    local sign_id
    sign_id="$(signing_identity)"

    codesign --force --sign "$sign_id" \
        --identifier com.meetingpipe.daemon \
        "$app"

    # Sanity-check: a future codesign incompatibility should surface here, not
    # at the next reinstall when permissions silently break. A bound Info.plist
    # and a stable Identifier are the two properties TCC stability depends on.
    local sign_info
    sign_info="$(codesign -dvv "$app" 2>&1)"
    if ! grep -q "Identifier=com.meetingpipe.daemon$" <<<"$sign_info"; then
        printf "\033[1;33m!!\033[0m %s\n" "codesign Identifier mismatch - permissions may not survive reinstall" >&2
    fi
    if ! grep -q "Info.plist entries=" <<<"$sign_info"; then
        printf "\033[1;33m!!\033[0m %s\n" "codesign Info.plist not bound - permissions may not survive reinstall" >&2
    fi
}
