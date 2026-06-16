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

DEV_CERT_CN="MeetingPipe Dev"

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
    if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT_CN"; then
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
    # the -A ACL with no password.
    local tmp keychain ok=1 p12pass="meetingpipe-dev-transient"
    tmp="$(mktemp -d)" || return 0
    keychain="$HOME/Library/Keychains/login.keychain-db"

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
        # -A: let any tool use the key without a per-build keychain prompt. This
        # is a local, untrusted, dev-only signing key (no value off this machine),
        # so the broad ACL is an acceptable trade for a prompt-free rebuild loop.
        if ! security import "$tmp/id.p12" -P "$p12pass" -A -k "$keychain" >/dev/null 2>&1; then
            security import "$tmp/id.p12" -P "$p12pass" -A >/dev/null 2>&1 || ok=0
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
