#!/usr/bin/env bash
# Gate matrix for the Keychain helpers install.sh uses (SEC23): scripts/lib/keychain.sh.
#
# Drives them against a stub `security` (SECURITY_BIN) that records every argv and every `-i` stdin
# line, so it pins the two properties that matter without touching the real login Keychain:
# a token never appears in argv, and secrets.env is only deleted once every managed key is stored.
# Invokes no real security binary and mutates nothing outside its temp dir.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub keeping its "Keychain" in $TMP/kc/<account> and a log of argv + stdin in $TMP/log.
# STUB_FAIL_SET=<account> makes the add for that account fail (status 1); STUB_UNREADABLE=<account>
# makes its find fail with status 36 (a locked keychain), not 44.
cat > "$TMP/security" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$STUB_DIR/kc"
echo "ARGV: $*" >> "$STUB_DIR/log"
case "$1" in
  -i)
    while IFS= read -r line; do
      echo "STDIN: $line" >> "$STUB_DIR/log"
      acct=$(sed -n 's/.* -a "\([A-Z0-9_]*\)".*/\1/p' <<<"$line")
      if [[ -n "${STUB_FAIL_SET:-}" && "$acct" == "$STUB_FAIL_SET" ]]; then exit 1; fi
      val=$(sed -n 's/.* -w "\(.*\)"$/\1/p' <<<"$line")
      val="${val//\\\"/\"}"; val="${val//\\\\/\\}"
      printf '%s' "$val" > "$STUB_DIR/kc/$acct"
    done
    exit 0 ;;
  find-generic-password)
    while [[ $# -gt 0 ]]; do [[ "$1" == "-a" ]] && acct="$2"; shift; done
    if [[ "${STUB_UNREADABLE:-}" == "$acct" ]]; then exit 36; fi
    [[ -f "$STUB_DIR/kc/$acct" ]] || exit 44
    cat "$STUB_DIR/kc/$acct"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/security"

export STUB_DIR="$TMP" SECURITY_BIN="$TMP/security"
# shellcheck source=scripts/lib/keychain.sh
source "$HERE/lib/keychain.sh"

reset() { rm -rf "$TMP/kc" "$TMP/log"; unset STUB_FAIL_SET STUB_UNREADABLE; mkdir -p "$TMP/kc"; : > "$TMP/log"; }
env_file() { printf '%s\n' "$@" > "$TMP/secrets.env"; }

# --- kc_set --------------------------------------------------------------
reset
kc_set ANTHROPIC_API_KEY 'sk-ant-SECRETVALUE' && ok "kc_set succeeds" || fail "kc_set succeeds"
grep -q '^ARGV: -i$' "$TMP/log" && ok "security launched with argv -i only" || fail "security launched with argv -i only"
grep '^ARGV:' "$TMP/log" | grep -q 'SECRETVALUE' && fail "token absent from argv" || ok "token absent from argv"
grep -q '^STDIN: .*SECRETVALUE' "$TMP/log" && ok "token present on stdin" || fail "token present on stdin"

reset
kc_set NOTION_TOKEN 'a b"c$HOME\d' && [[ "$(cat "$TMP/kc/NOTION_TOKEN")" == 'a b"c$HOME\d' ]] \
    && ok "quote, backslash, dollar and space round-trip" || fail "quote, backslash, dollar and space round-trip"

reset
kc_set NOTION_TOKEN $'line1\nline2'; [[ $? -eq 2 && ! -s "$TMP/log" ]] && ok "newline refused before security runs" || fail "newline refused before security runs"
kc_set NOTION_TOKEN $'tok\x07en'; [[ $? -eq 2 ]] && ok "control byte refused" || fail "control byte refused"
kc_set NOTION_TOKEN 'tökën'; [[ $? -eq 2 ]] && ok "non-ASCII refused" || fail "non-ASCII refused"
kc_set NOTION_TOKEN ''; [[ $? -eq 2 ]] && ok "empty value refused" || fail "empty value refused"

# --- kc_get --------------------------------------------------------------
reset
kc_get NOTION_TOKEN >/dev/null; [[ $? -eq 44 ]] && ok "absent is 44" || fail "absent is 44"
printf 'x' > "$TMP/kc/NOTION_TOKEN"
[[ "$(kc_get NOTION_TOKEN)" == "x" ]] && ok "found prints the value" || fail "found prints the value"
STUB_UNREADABLE=NOTION_TOKEN kc_get NOTION_TOKEN >/dev/null; [[ $? -eq 36 ]] && ok "locked keychain is its own status, not 44" || fail "locked keychain is its own status, not 44"

# --- migration -----------------------------------------------------------
reset
env_file 'ANTHROPIC_API_KEY=sk-a' 'NOTION_TOKEN=ntn-b' 'HF_TOKEN=hf-c' 'OPENAI_API_KEY="sk-oai"' '# c' 'UNMANAGED=zzz'
kc_migrate_secrets_env "$TMP/secrets.env" >/dev/null
rc=$?
[[ $rc -eq 0 && ! -e "$TMP/secrets.env" ]] && ok "all set: file removed" || fail "all set: file removed"
[[ "$(cat "$TMP/kc/OPENAI_API_KEY" 2>/dev/null)" == "sk-oai" ]] && ok "OPENAI_API_KEY is migrated" || fail "OPENAI_API_KEY is migrated"
[[ ! -e "$TMP/kc/UNMANAGED" ]] && ok "unmanaged key not absorbed" || fail "unmanaged key not absorbed"
grep '^ARGV:' "$TMP/log" | grep -Eq 'sk-a|ntn-b|hf-c|sk-oai' && fail "no migrated token in argv" || ok "no migrated token in argv"

reset
env_file 'ANTHROPIC_API_KEY=sk-a' 'NOTION_TOKEN=ntn-b'
STUB_FAIL_SET=NOTION_TOKEN kc_migrate_secrets_env "$TMP/secrets.env" >/dev/null 2>&1
rc=$?
[[ $rc -eq 1 && -e "$TMP/secrets.env" ]] && ok "a failed set keeps the file" || fail "a failed set keeps the file"
[[ "$(cat "$TMP/kc/ANTHROPIC_API_KEY" 2>/dev/null)" == "sk-a" ]] && ok "keys that did set are stored" || fail "keys that did set are stored"

reset
env_file 'ANTHROPIC_API_KEY=sk-from-file'
printf 'sk-existing' > "$TMP/kc/ANTHROPIC_API_KEY"
kc_migrate_secrets_env "$TMP/secrets.env" >/dev/null 2>&1
[[ "$(cat "$TMP/kc/ANTHROPIC_API_KEY")" == "sk-existing" && ! -e "$TMP/secrets.env" ]] \
    && ok "an existing key is not overwritten, file still goes" || fail "an existing key is not overwritten, file still goes"

reset
env_file 'ANTHROPIC_API_KEY=sk-from-file'
printf 'sk-existing' > "$TMP/kc/ANTHROPIC_API_KEY"
STUB_UNREADABLE=ANTHROPIC_API_KEY kc_migrate_secrets_env "$TMP/secrets.env" >/dev/null 2>&1
rc=$?
[[ $rc -eq 1 && -e "$TMP/secrets.env" && "$(cat "$TMP/kc/ANTHROPIC_API_KEY")" == "sk-existing" ]] \
    && ok "an unreadable key is not overwritten and the file stays" || fail "an unreadable key is not overwritten and the file stays"
! grep -q '^STDIN:' "$TMP/log" && ok "no write attempted over an unreadable key" || fail "no write attempted over an unreadable key"

reset
printf 'ANTHROPIC_API_KEY=sk-no-newline' > "$TMP/secrets.env"
kc_migrate_secrets_env "$TMP/secrets.env" >/dev/null 2>&1
[[ "$(cat "$TMP/kc/ANTHROPIC_API_KEY" 2>/dev/null)" == "sk-no-newline" ]] && ok "a last line without a newline is migrated" || fail "a last line without a newline is migrated"

echo
if [[ $failures -ne 0 ]]; then echo "$failures failure(s)"; exit 1; fi
echo "all ok"
