#!/usr/bin/env bash
# Shared app-bundle signing for install.sh and rebuild.sh. Sourced, not run.
#
# SwiftPM ships each target's resource bundle as a directory with a `.bundle`
# suffix but no Info.plist, and codesign refuses to treat it as a valid macOS
# bundle ("bundle format unrecognized, invalid, or unsuitable"). So we two-pass
# sign: write a minimal Info.plist into each resource bundle and sign it with
# its own identifier, then sign the outer .app with the stable
# `com.meetingpipe.daemon` identifier.
#
# A plain adhoc re-sign with `--identifier` set to the bundle id binds the
# Info.plist and seals the resources, giving TCC a stable (bundle_id,
# identifier) pair across rebuilds. The cdhash still changes per rebuild (no
# paid Developer ID), so Screen Recording needs one re-toggle, but Mic /
# Notifications / Accessibility grants survive.
#
# This lives in one place so install.sh and rebuild.sh cannot drift again. The
# drift is exactly what left rebuild.sh trying to codesign the plist-less
# bundles and aborting mid-run (new binary copied, app left unsigned, daemon
# not relaunched).

# sign_app_with_resources <app_path>
#   Two-pass sign every resource bundle inside <app>/Contents/MacOS, then the
#   app itself. Runs under the caller's `set -e`, so a codesign failure aborts.
sign_app_with_resources() {
    local app="$1"
    local resource_bundle bundle_name bundle_id

    for resource_bundle in "$app/Contents/MacOS/"*.bundle; do
        [[ -d "$resource_bundle" ]] || continue
        bundle_name="$(basename "$resource_bundle" .bundle)"
        bundle_id="com.meetingpipe.daemon.resources.$(tr '[:upper:]' '[:lower:]' <<<"$bundle_name")"
        if [[ ! -f "$resource_bundle/Info.plist" ]]; then
            cat >"$resource_bundle/Info.plist" <<BUNDLE_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleName</key>
    <string>$bundle_name</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
</dict>
</plist>
BUNDLE_PLIST
        fi
        codesign --force --sign - --identifier "$bundle_id" "$resource_bundle"
    done

    codesign --force --sign - \
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
