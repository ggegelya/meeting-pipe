# shellcheck shell=bash
# Keychain helpers for install.sh (SEC8, SEC23). Sourced, never executed.
#
# Same service + account contract as daemon/Sources/MeetingPipe/KeychainSecrets.swift and
# pipeline/src/mp/config.py, all through /usr/bin/security so the item's ACL has one stable accessor.
# Split out of install.sh so scripts/test-keychain-migration.sh can drive it against a stub `security`
# (SECURITY_BIN) instead of the real login Keychain.
#
# Callers run under `set -e`: every helper here returns its status instead of relying on it, and a
# caller that wants the status writes `kc_get X >/dev/null && ... || status=$?` or an `if`.

KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-com.meetingpipe.daemon}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
# Mirrors KeychainSecrets.managedKeys. OPENAI_API_KEY used to be missing from the migration, so that
# token was deleted with the file and never migrated.
KC_MANAGED_KEYS="ANTHROPIC_API_KEY NOTION_TOKEN HF_TOKEN OPENAI_API_KEY"

# Fallbacks so the test can source this file on its own.
declare -F say  >/dev/null || say()  { printf '%s\n' "$*"; }
declare -F warn >/dev/null || warn() { printf '%s\n' "$*" >&2; }

# kc_get ACCOUNT: prints the token. Returns 0 found, 44 not found (also an empty value), anything else
# means the Keychain could not be read (locked, ACL denied, security not runnable), which a caller must
# not treat as "absent".
kc_get() {
    local out status=0
    out=$("$SECURITY_BIN" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null) || status=$?
    if [[ $status -eq 0 ]]; then
        [[ -n "$out" ]] || return 44
        printf '%s\n' "$out"
        return 0
    fi
    return "$status"
}

# kc_set ACCOUNT VALUE: stores the token through `security -i`, so the value travels on stdin and `ps`
# shows only `security -i`. Returns 0 on success, 2 when the value cannot be quoted safely (a newline
# would end the command early, other control and non-ASCII bytes are untested), else security's status.
# `printf` is a builtin, so the value never reaches any argv. Inside double quotes `security -i` honours
# backslash escapes and does not expand `$`; only backslash and double quote need escaping.
kc_set() {
    local account="$1" value="$2"
    case "$account" in *[!A-Z0-9_]*|"") return 2 ;; esac
    (
        LC_ALL=C
        case "$value" in *[!\ -~]*|"") exit 2 ;; esac
        exit 0
    ) || return 2
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' "$KEYCHAIN_SERVICE" "$account" "$value" \
        | "$SECURITY_BIN" -i >/dev/null 2>&1
}

# kc_migrate_secrets_env FILE: moves the managed keys of a legacy secrets.env into the Keychain and
# removes FILE only when every one of them is now there (set just now, or already present). A key whose
# existing value cannot be read is neither overwritten nor counted as stored, so the file stays and the
# next run retries. Returns 0 when FILE is gone, 1 when it was kept.
kc_migrate_secrets_env() {
    local file="$1" complete=1 raw_key raw_val key val status
    while IFS='=' read -r raw_key raw_val || [[ -n "$raw_key" ]]; do
        key="${raw_key//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        case " $KC_MANAGED_KEYS " in *" $key "*) ;; *) continue ;; esac
        val="${raw_val//$'\r'/}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [[ "$val" == \"*\" ]] && { val="${val#\"}"; val="${val%\"}"; }
        [[ -n "$val" ]] || continue
        status=0
        kc_get "$key" >/dev/null || status=$?
        if [[ $status -eq 0 ]]; then
            continue
        elif [[ $status -eq 44 ]]; then
            if kc_set "$key" "$val"; then
                say "  migrated $key"
            else
                warn "  could not store $key in the Keychain"
                complete=0
            fi
        else
            warn "  could not read $key from the Keychain (status $status); leaving it alone"
            complete=0
        fi
    done < "$file"
    if [[ $complete -eq 1 ]]; then
        rm -f "$file"
        return 0
    fi
    return 1
}
