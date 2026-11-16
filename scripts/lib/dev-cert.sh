#!/usr/bin/env bash
# Stable local code-signing identity for install.sh and rebuild.sh. Sourced, not run.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) gives the app a
# designated requirement pinned to the binary's cdhash, which changes on every
# rebuild. macOS re-validates Screen Recording against that cdhash, so the grant
# breaks on every build: System Settings still shows the toggle ON, but the
# daemon is silently denied and ScreenCaptureKit re-pops the prompt on every
# poll. A self-signed certificate gives an identity-based requirement
# (`identifier "..." and certificate leaf = H"..."`) that does NOT pin the
# cdhash, so the grant survives rebuilds: Screen Recording is granted once and
# stays granted.
#
# This is the same mechanism a paid Apple Developer ID uses, just self-signed
# and local (other Macs do not trust it, which is fine for a single-user dev
# install). Going paid later is a swap, not a teardown:
#   - export MEETINGPIPE_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#     and it takes over; the dev cert below goes unused.
# Remove the dev cert any time with:
#   security delete-identity -c "MeetingPipe Dev"
# (`./scripts/uninstall.sh --reset-tcc` does it for you, since the grants it
# resets are the only thing the identity was keeping alive.)
#
# What the key is worth on this Mac (SEC17, F130): the app's designated
# requirement is `identifier "com.meetingpipe.daemon" and certificate leaf =
# H"..."`, and the Microphone, Screen Recording and Accessibility grants are
# bound to it. So anything that can sign with this private key produces code
# those grants accept. "No value off this machine" is true, and on this machine
# is exactly where the value is. New keys are imported with
# `-T /usr/bin/codesign` rather than `-A`, so the key's ACL names codesign
# instead of any application. That narrows the exposure and does not close it:
# any same-user process can run /usr/bin/codesign, and it is prompt-free, which
# the rebuild loop depends on. Only an ACL that prompts before codesign may use
# the key would close it (inferred, not tested), at the cost of a prompt on
# every rebuild. Hardened runtime (sign-app.sh) closes the other route, the
# DYLD_INSERT_LIBRARIES one; it does nothing about a binary signed with the key.
# A key created before this change still has the `-A` ACL. `scripts/signing-key-acl.sh`
# reports it and prints the in-place fix (Keychain Access, same key, one password
# prompt). Recreating the certificate is not an option (a new cert is a new leaf,
# which resets every TCC grant), and `security set-key-partition-list` was
# measured to narrow nothing.

DEV_CERT_CN="MeetingPipe Dev"
# The keychain the identity lives in. The override exists so the ACL tests can
# run against a scratch keychain and never touch the real login one.
DEV_CERT_KEYCHAIN="${MEETINGPIPE_DEV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# _dev_cert_present: is the identity in the keychain we manage? With the test
# override set, only that keychain is searched, so a real login identity cannot
# satisfy a scratch-keychain run.
_dev_cert_present() {
    if [[ -n "${MEETINGPIPE_DEV_KEYCHAIN:-}" ]]; then
        security find-identity -p codesigning "$DEV_CERT_KEYCHAIN" 2>/dev/null | grep -q "$DEV_CERT_CN"
    else
        security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT_CN"
    fi
}

# dev_key_trusts_any_app: succeeds when the private key's `sign` authorization
# is open to any application (the `-A` import), fails when it names specific
# applications (`-T`). A private key's label is its attribute 0x00000001 in
# the dump (`labl` belongs to the certificate record). Reads the ACL listing only; no secret is read, so nothing
# prompts. `security dump-keychain -a` walks the whole keychain, so this is for
# the hardening script and the tests, not the rebuild loop.
dev_key_trusts_any_app() {
    security dump-keychain -a "$DEV_CERT_KEYCHAIN" 2>/dev/null | awk -v label="$DEV_CERT_CN" '
        function flush() { if (key && lab && any_open) hit = 1; key = 0; lab = 0; any_open = 0; sign = 0 }
        /^keychain:/ { flush() }
        /class: 0x00000010/ { key = 1 }
        key && /^ *entry [0-9]+:/ { sign = 0 }
        key && /authorizations \([0-9]+\):/ { sign = ($0 ~ /[ ,]sign([ ,]|$)/) }
        key && /applications: <null>/ { if (sign) any_open = 1 }
        key && /0x00000001 <blob>=/ { if (index($0, "\"" label "\"")) lab = 1 }
        END { flush(); exit !hit }
    '
}

# delete_dev_identity: remove the self-signed identity (cert and key). Used by
# `uninstall.sh --reset-tcc`. "Not found" is not an error. Scoped to the scratch
# keychain when MEETINGPIPE_DEV_KEYCHAIN is set, so a test can never reach the real one.
delete_dev_identity() {
    if [[ -n "${MEETINGPIPE_DEV_KEYCHAIN:-}" ]]; then
        security delete-identity -c "$DEV_CERT_CN" "$DEV_CERT_KEYCHAIN" >/dev/null 2>&1
    else
        security delete-identity -c "$DEV_CERT_CN" >/dev/null 2>&1
    fi
}

# signing_identity: echo the codesign identity to use, best available first.
#   1. $MEETINGPIPE_SIGN_ID  - explicit override (a paid Developer ID, CI, ...)
#   2. "MeetingPipe Dev"     - the local self-signed cert, if present
#   3. "-"                   - ad-hoc fallback (a fresh clone with no cert still builds)
# NOTE: `find-identity` is queried WITHOUT `-v`. A self-signed cert is not
# policy-trusted (`CSSMERR_TP_NOT_TRUSTED`), so `-v` (valid-only) hides it, but
# codesign signs with it fine and the resulting requirement is still
# identity-based. Using `-v` here would silently fall back to ad-hoc.
signing_identity() {
    if [[ -n "${MEETINGPIPE_SIGN_ID:-}" ]]; then
        printf '%s' "$MEETINGPIPE_SIGN_ID"
    elif security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT_CN"; then
        printf '%s' "$DEV_CERT_CN"
    else
        printf '%s' "-"
    fi
}

# ensure_dev_cert: create the self-signed "MeetingPipe Dev" code-signing cert in
# the login keychain if it is not already there. Idempotent, user-level (no sudo).
# Best-effort: any failure degrades to ad-hoc signing rather than aborting the
# caller's `set -e`. No-op when an explicit MEETINGPIPE_SIGN_ID override is set.
ensure_dev_cert() {
    [[ -n "${MEETINGPIPE_SIGN_ID:-}" ]] && return 0
    if _dev_cert_present; then
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        printf "\033[1;33m!!\033[0m %s\n" "openssl not found; staying on ad-hoc signing (Screen Recording will need a re-toggle per rebuild)" >&2
        return 0
    fi

    # A non-empty PKCS#12 password is required: `security import` fails MAC
    # verification on an empty-password p12. (Algorithm choice matters too; see
    # the -legacy note below.) The password is transient (only for the
    # export/import handshake); the imported key is then usable by codesign via
    # the -T /usr/bin/codesign ACL with no password.
    local tmp keychain ok=1 p12pass="meetingpipe-dev-transient"
    tmp="$(mktemp -d)" || return 0
    keychain="$DEV_CERT_KEYCHAIN"

    cat >"$tmp/req.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = MeetingPipe Dev
[ v3 ]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/req.cnf" >/dev/null 2>&1 || ok=0
    if (( ok )); then
        # OpenSSL 3.x defaults PKCS#12 to AES-256 + a non-SHA1 MAC that Apple's
        # Security-framework parser rejects ("MAC verification failed during
        # PKCS12 import"), so `security import` below fails and we fall back to
        # ad-hoc. `-legacy` forces the SHA1/3DES algorithms it can read. The flag
        # is OpenSSL-3-only; the system LibreSSL lacks it and already writes the
        # legacy format, so pass it only when `pkcs12 -help` advertises it.
        local legacy_flag=""
        openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && legacy_flag="-legacy"
        # shellcheck disable=SC2086  # single bare flag or empty; intentional split
        openssl pkcs12 -export $legacy_flag -name "$DEV_CERT_CN" \
            -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -out "$tmp/id.p12" -passout "pass:$p12pass" >/dev/null 2>&1 || ok=0
    fi
    if (( ok )); then
        # -T /usr/bin/codesign: only codesign may use the key without a prompt,
        # which is what keeps the rebuild loop prompt-free. It used to be -A
        # (any application). The residual is in the header: any same-user
        # process can still run /usr/bin/codesign.
        if ! security import "$tmp/id.p12" -P "$p12pass" -T /usr/bin/codesign -k "$keychain" >/dev/null 2>&1; then
            if [[ -n "${MEETINGPIPE_DEV_KEYCHAIN:-}" ]]; then
                ok=0   # a scratch run never falls back to the default keychain
            else
                security import "$tmp/id.p12" -P "$p12pass" -T /usr/bin/codesign >/dev/null 2>&1 || ok=0
            fi
        fi
    fi

    rm -rf "$tmp"

    if (( ok )); then
        printf "\033[1;34m==>\033[0m %s\n" "created self-signed code-signing cert '$DEV_CERT_CN' (Screen Recording now survives rebuilds)"
    else
        printf "\033[1;33m!!\033[0m %s\n" "could not create '$DEV_CERT_CN'; staying on ad-hoc signing (Screen Recording will need a re-toggle per rebuild)" >&2
    fi
    return 0
}
