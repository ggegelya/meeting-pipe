#!/usr/bin/env bash
# Report who may use the "MeetingPipe Dev" signing key without a prompt, and say how to narrow it (SEC17).
#
# Keys created before SEC17 were imported with `-A`: any application may use the private key with no
# prompt. New keys are imported with `-T /usr/bin/codesign`, which refuses every other application
# (measured: a non-Apple process gets CSSMERR_CSP_OPERATION_AUTH_DENIED, while codesign still signs).
#
# This does NOT change the key, on purpose, and that is the measured result and not a shortcut:
#   - `security set-key-partition-list` leaves an `-A` key fully usable by a non-Apple process (tested
#     on a scratch keychain: the same process signs before and after), so it narrows nothing.
#   - Recreating the certificate narrows it and resets every Microphone, Screen Recording and
#     Accessibility grant, because the app's designated requirement pins the certificate leaf.
#   - The in-place change that keeps the same key is the Keychain Access one below, which asks for your
#     login password once. The command line has no way to edit an existing key's application list.
#
# Usage: ./scripts/signing-key-acl.sh      exit 0 when the key names specific applications,
#                                           1 when it is open to any application, 2 when there is no key.
# `MEETINGPIPE_DEV_KEYCHAIN` points it at a scratch keychain for tests (scripts/test-dev-cert-acl.sh).

set -euo pipefail

# shellcheck source=scripts/lib/dev-cert.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/dev-cert.sh"

if ! _dev_cert_present; then
    echo "No '$DEV_CERT_CN' signing identity in $DEV_CERT_KEYCHAIN (run ./scripts/rebuild.sh once to create it)."
    exit 2
fi

if ! dev_key_trusts_any_app; then
    echo "The '$DEV_CERT_CN' key names specific applications (codesign), not any application. Nothing to do."
    exit 0
fi

cat <<TXT
The '$DEV_CERT_CN' key can be used by ANY application on this Mac without a prompt (it was imported with -A).
Hardened runtime closes the DYLD route into the app, but a process that can use this key can still sign code the
app's permissions accept. To narrow it WITHOUT creating a new key (a new key resets every permission):

  1. Open Keychain Access, choose the "login" keychain, category "My Certificates".
  2. Expand "$DEV_CERT_CN", double-click the private key under it.
  3. Access Control tab: choose "Allow access by these applications", remove everything but
     /usr/bin/codesign (use + and Cmd-Shift-G to add it), and tick "Ask for Keychain password".
  4. Save Changes; macOS asks for your login password once.

Then run ./scripts/rebuild.sh once to confirm signing still works without a prompt. What stays open, and cannot
be closed without a prompt on every rebuild: any process on this account can run /usr/bin/codesign.
TXT
exit 1
