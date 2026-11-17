#!/usr/bin/env bash
# Gate matrix for the signing key's ACL (SEC17), against SCRATCH keychains.
#
# `ensure_dev_cert` must import a new key trusted for /usr/bin/codesign rather than any
# application, `dev_key_trusts_any_app` must tell the two apart, scripts/signing-key-acl.sh must
# report them, and the difference must be real: a non-Apple process is refused by the `-T` key and
# allowed by the `-A` key, while codesign signs with the `-T` one. All of it runs with
# MEETINGPIPE_DEV_KEYCHAIN pointed at keychains created here, so the owner's login keychain, its
# "MeetingPipe Dev" identity and the app are never touched; it refuses to finish green if the
# keychain search list changed underneath it. macOS only (needs /usr/bin/security and codesign).

set -u

[[ "$(uname)" == Darwin ]] || { echo "not macOS; not run"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "openssl not found; not run"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

ROOT="$(mktemp -d)"
LISTS_BEFORE="$(security list-keychains -d user 2>/dev/null)"
cleanup() {
    [[ -n "${GITHUB_ACTIONS:-}" ]] && eval "security list-keychains -d user -s $LISTS_BEFORE" 2>/dev/null
    for kc in "$ROOT"/*.keychain-db; do
        [[ -e "$kc" ]] && security delete-keychain "$kc" >/dev/null 2>&1
    done
    rm -rf "$ROOT"
}
trap cleanup EXIT

new_keychain() {
    security create-keychain -p pw "$1" >/dev/null 2>&1 && security unlock-keychain -p pw "$1" >/dev/null 2>&1
}
cert_fp() { security find-certificate -c "MeetingPipe Dev" -Z "$1" 2>/dev/null | awk '/SHA-1 hash:/{print $3; exit}'; }
acl() { (MEETINGPIPE_DEV_KEYCHAIN="$1" bash "$HERE/signing-key-acl.sh" >"$ROOT/acl.out" 2>&1); }

echo "a new key (ensure_dev_cert)"
KC_T="$ROOT/new.keychain-db"
new_keychain "$KC_T" || { fail "could not create a scratch keychain"; exit 1; }
(
    export MEETINGPIPE_DEV_KEYCHAIN="$KC_T"
    # shellcheck source=scripts/lib/dev-cert.sh
    source "$HERE/lib/dev-cert.sh"
    ensure_dev_cert >/dev/null 2>&1
    _dev_cert_present
) && ok "the identity was created in the scratch keychain" || fail "the identity was created in the scratch keychain"
check "the key is not open to any application" \
    '! (MEETINGPIPE_DEV_KEYCHAIN="$KC_T"; source "$HERE/lib/dev-cert.sh"; dev_key_trusts_any_app)'
check "its ACL lists an application list for sign, not <null>" \
    'security dump-keychain -a "$KC_T" 2>/dev/null | awk "/class: 0x00000010/{f=1} f&&/applications \\([1-9]/{n=1} END{exit !n}"'
cp /usr/bin/true "$ROOT/t"
# macOS 15's codesign (the CI runner's) resolves the identity through the user's search list
# even with --keychain, and reports "could not be found in the keychain" otherwise; this Mac's
# does not. The runner is thrown away after the job, so there alone the scratch keychain joins
# the list for the two signing checks and the list is put back straight after. Locally it is never touched.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    eval "security list-keychains -d user -s \"\$KC_T\" $LISTS_BEFORE"
fi
check "codesign signs with it from the scratch keychain, prompt-free" \
    'codesign --force --sign "MeetingPipe Dev" --keychain "$KC_T" "$ROOT/t" >"$ROOT/codesign.out" 2>&1 \
        || { sed "s/^/        codesign: /" "$ROOT/codesign.out"; false; }'
check "and the signature's leaf is the scratch certificate, not some other identity" \
    '[[ -n "$(cert_fp "$KC_T")" ]] && codesign -dvv "$ROOT/t" 2>&1 | grep -q "Authority=MeetingPipe Dev"'
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    eval "security list-keychains -d user -s $LISTS_BEFORE"
fi
acl "$KC_T"; rc=$?
check "signing-key-acl.sh reports it as fine (exit 0)" '[[ $rc == 0 ]]'

echo "an old -A key"
KC_A="$ROOT/old.keychain-db"
new_keychain "$KC_A" || { fail "could not create the second scratch keychain"; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$ROOT/k.pem" -out "$ROOT/c.pem" \
    -subj "/CN=MeetingPipe Dev" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
legacy=""; openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && legacy="-legacy"
# shellcheck disable=SC2086
openssl pkcs12 -export $legacy -name "MeetingPipe Dev" -inkey "$ROOT/k.pem" -in "$ROOT/c.pem" \
    -out "$ROOT/old.p12" -passout pass:tr >/dev/null 2>&1
security import "$ROOT/old.p12" -P tr -A -k "$KC_A" >/dev/null 2>&1
check "an -A import reads as open to any application" \
    '(MEETINGPIPE_DEV_KEYCHAIN="$KC_A"; source "$HERE/lib/dev-cert.sh"; dev_key_trusts_any_app)'
acl "$KC_A"; rc=$?
check "signing-key-acl.sh reports it (exit 1) and prints the in-place fix" \
    '[[ $rc == 1 ]] && grep -q "Keychain Access" "$ROOT/acl.out" && grep -q "WITHOUT creating a new key" "$ROOT/acl.out"'
EMPTY="$ROOT/empty.keychain-db"; new_keychain "$EMPTY"
acl "$EMPTY"; rc=$?
check "signing-key-acl.sh says so when there is no key (exit 2)" '[[ $rc == 2 ]]'

echo "the difference is enforced, not just listed"
if command -v swiftc >/dev/null 2>&1; then
    cat > "$ROOT/use.swift" <<'SWIFT'
import Foundation
import Security
// Try to sign with the scratch keychain's private key as a non-Apple process, never showing UI.
SecKeychainSetUserInteractionAllowed(false)
var kc: SecKeychain?
SecKeychainOpen(CommandLine.arguments[1], &kc)
let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchSearchList as String: [kc!], kSecReturnRef as String: true]
var ref: CFTypeRef?
guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess else { exit(3) }
var key: SecKey?
SecIdentityCopyPrivateKey(ref as! SecIdentity, &key)
var err: Unmanaged<CFError>?
exit(SecKeyCreateSignature(key!, .rsaSignatureMessagePKCS1v15SHA256, Data("x".utf8) as CFData, &err) != nil ? 0 : 1)
SWIFT
    if swiftc -o "$ROOT/use" "$ROOT/use.swift" >/dev/null 2>&1; then
        check "a non-Apple process is REFUSED by the -T codesign key" '! "$ROOT/use" "$KC_T"'
        check "the same process is ALLOWED by the -A key (what the old import did)" '"$ROOT/use" "$KC_A"'
    else
        fail "could not compile the non-Apple probe"
    fi
else
    echo "  skip  swiftc not found; enforcement probe not run"
fi

echo "delete_dev_identity (uninstall --reset-tcc) honours the scratch keychain"
check "it removes the identity from the scratch keychain" \
    '(MEETINGPIPE_DEV_KEYCHAIN="$KC_A"; source "$HERE/lib/dev-cert.sh"; delete_dev_identity; ! _dev_cert_present)'

echo "the keychain search list"
check "unchanged by this test" '[[ "$(security list-keychains -d user 2>/dev/null)" == "$LISTS_BEFORE" ]]'

if (( failures )); then
    printf '%d case(s) failed\n' "$failures"
    exit 1
fi
echo "all cases passed"
