#!/usr/bin/env bash
# DYLD injection against a hardened and a non-hardened build (SEC17).
#
# Builds a tiny binary and a dylib whose constructor writes a marker file, signs the binary the
# way sign_app_with_resources does (--options runtime plus scripts/MeetingPipe.entitlements) and
# the way it used to (no runtime flag), then starts each with DYLD_INSERT_LIBRARIES pointing at
# the dylib. The pre-change build must load it (marker present) and the hardened one must not
# (marker absent), and the entitlements must be exactly the audio-input key. The app itself is
# never launched and no real identity is used (ad-hoc). Needs clang (Xcode or its Command Line Tools).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ENT="$HERE/MeetingPipe.entitlements"
failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

[[ "$(uname)" == Darwin ]] || { echo "not macOS; not run"; exit 0; }
command -v clang >/dev/null 2>&1 || { echo "clang not found; not run"; exit 0; }
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

cat > "$ROOT/main.c" <<'C'
int main(void) { return 0; }
C
cat > "$ROOT/inject.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void injected(void) {
    const char *path = getenv("INJECT_MARKER");
    if (!path) return;
    FILE *f = fopen(path, "w");
    if (f) { fputs("loaded", f); fclose(f); }
}
C
clang -o "$ROOT/plain" "$ROOT/main.c" 2>/dev/null || { fail "could not compile the test binary"; exit 1; }
clang -dynamiclib -o "$ROOT/inject.dylib" "$ROOT/inject.c" 2>/dev/null || { fail "could not compile the test dylib"; exit 1; }
codesign --force --sign - "$ROOT/inject.dylib" >/dev/null 2>&1

cp "$ROOT/plain" "$ROOT/old"
codesign --force --sign - --identifier com.meetingpipe.daemon "$ROOT/old" >/dev/null 2>&1
cp "$ROOT/plain" "$ROOT/hardened"
codesign --force --sign - --options runtime --entitlements "$ENT" --identifier com.meetingpipe.daemon "$ROOT/hardened" >/dev/null 2>&1

inject() { rm -f "$ROOT/marker"; INJECT_MARKER="$ROOT/marker" DYLD_INSERT_LIBRARIES="$ROOT/inject.dylib" "$1" >/dev/null 2>&1; [[ -e "$ROOT/marker" ]]; }

echo "injection"
check "the pre-change signature (no runtime flag) loads the injected library" 'inject "$ROOT/old"'
check "the hardened build still launches and exits cleanly with no injection" '"$ROOT/hardened"'
# dyld honours the hardened runtime's DYLD_* restriction only with System Integrity Protection on.
# GitHub's macOS runners run with SIP disabled, where every binary loads the library, so there the
# case is reported as not provable rather than failed. The owner's Mac (SIP on) still proves it.
if csrutil status 2>/dev/null | grep -q "status: disabled"; then
    printf '  n/a   the hardened runtime signature does not load the injected library (SIP is disabled here, so dyld cannot enforce it)\n'
else
    check "the hardened runtime signature does not load the injected library" '! inject "$ROOT/hardened"'
fi

echo "signature"
check "codesign reports the runtime flag" 'codesign -dvv "$ROOT/hardened" 2>&1 | grep -Eq "flags=0x[0-9a-f]+\([^)]*runtime"'
check "the old build reports no runtime flag" '! codesign -dvv "$ROOT/old" 2>&1 | grep -q "runtime"'
ents="$(codesign -d --entitlements - --xml "$ROOT/hardened" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)"
check "the entitlements are exactly the audio-input key" '[[ "$ents" == "{\"com.apple.security.device.audio-input\":true}" ]]'

if (( failures )); then
    printf '%d case(s) failed\n' "$failures"
    exit 1
fi
echo "all cases passed"
