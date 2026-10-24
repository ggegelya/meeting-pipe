#!/usr/bin/env bash
# Where the app's SwiftPM resource bundles go (DIST4). Sourced, not run; shared
# by install.sh, rebuild.sh and scripts/test-app-relocation.sh, so the three
# cannot disagree.
#
# They go in Contents/Resources, which is where the daemon's
# ResourceBundleLocator looks (Bundle.main.resourceURL). They used to sit beside
# the binary in Contents/MacOS, where SwiftPM's generated Bundle.module never
# looks either: it tries the .app root, then an absolute path into
# <repo>/daemon/.build, then calls fatalError. So the installed app only worked
# while the build tree existed, and crash-looped under launchd once it moved.

# install_resource_bundles <build_dir> <app_path>
#   Replace the app's MeetingPipe_*.bundle copies in Contents/Resources with the
#   build's, and remove any an install from before DIST4 left in Contents/MacOS.
#   Only this package's own bundles: a debug build dir that has run `swift test`
#   also holds the test targets' fixture bundles, which do not belong in an app.
install_resource_bundles() {
    local build_dir="$1" app="$2" bundle name
    mkdir -p "$app/Contents/Resources"
    rm -rf "$app/Contents/MacOS/"MeetingPipe_*.bundle "$app/Contents/Resources/"MeetingPipe_*.bundle
    for bundle in "$build_dir/"MeetingPipe_*.bundle; do
        [[ -d "$bundle" ]] || continue
        name="$(basename "$bundle")"
        [[ "$name" == *Tests.bundle ]] && continue
        ditto "$bundle" "$app/Contents/Resources/$name"
    done
}
