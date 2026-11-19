#!/usr/bin/env bash
# The purge gate for scripts/uninstall.sh (DIST8). Sourced, not run.
#
# A plain uninstall keeps ~/Library/Application Support/MeetingPipe because it
# holds things nothing else has: originals/ (the only copy of a held-back or
# quarantined recording, in no backup and no Time Machine, ADR 0016; SEC26's
# held/ folder sits under it), corrections/ (the summary-grading corpus, which
# exists nowhere else) and auto_consent.json. --purge is the one way to delete
# them, so it lists what is about to go and asks first.

# DIST5: every launchd job the app installs under ~/Library/LaunchAgents. The daemon
# agent comes from install.sh; the digest and backup agents from the app itself
# (`DigestSchedulerService.label`, `BackupSchedulerService.label` through
# `LaunchAgentScheduler`). A plain uninstall used to leave those two loaded, firing
# into a deleted venv on schedule. A fourth scheduled job is one more word here.
# shellcheck disable=SC2034  # read by uninstall.sh, which sources this
UNINSTALL_AGENT_LABELS=(com.meetingpipe.daemon com.meetingpipe.digest com.meetingpipe.backup)

# DIST5 (F184): the Keychain accounts --purge clears. Must equal Swift's
# `KeychainSecrets.managedKeys`; scripts/test-uninstall.sh fails when they differ.
# It used to miss OPENAI_API_KEY.
# shellcheck disable=SC2034  # read by uninstall.sh and test-uninstall.sh
UNINSTALL_KEYCHAIN_ACCOUNTS=(ANTHROPIC_API_KEY NOTION_TOKEN HF_TOKEN OPENAI_API_KEY)

# The search embedder (Swift `EmbedderModel.id`) and the default local summarizer
# (`ConfigDefaults`), the two Hugging Face models the app downloads on its own.
UNINSTALL_EMBEDDER_MODEL="mlx-community/multilingual-e5-small-mlx"
UNINSTALL_DEFAULT_LOCAL_MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit"

# uninstall_configured_local_model <config.toml>: `summarization.local_model`, or the
# default when the file or the key is absent. A line read, like live-recording.sh's.
uninstall_configured_local_model() {
    local config="$1" value=""
    if [[ -f "$config" ]]; then
        value="$(awk '
            /^[[:space:]]*\[/ { in_s = ($0 ~ /^[[:space:]]*\[[[:space:]]*summarization[[:space:]]*\]/); next }
            in_s && /^[[:space:]]*local_model[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["\047]/, ""); print; exit
            }' "$config")"
    fi
    printf '%s' "${value:-$UNINSTALL_DEFAULT_LOCAL_MODEL}"
}

# uninstall_model_dirs <hf-hub-dir> <config.toml>: the cache directories of the models
# the app downloaded that exist, one per line (`models--<org>--<name>`, Hugging
# Face's own layout). Only those two repos, never every mlx-community model: another
# tool on this Mac may use the same cache.
uninstall_model_dirs() {
    local hub="$1" config="$2" repo dir
    for repo in "$(uninstall_configured_local_model "$config")" "$UNINSTALL_EMBEDDER_MODEL"; do
        dir="$hub/models--${repo//\//--}"
        [[ -d "$dir" ]] && printf '%s\n' "$dir"
    done
    return 0
}

# uninstall_dir_summary <dir>: "N files, SIZE", or "none" when absent.
uninstall_dir_summary() {
    local dir="$1" n size
    if [[ ! -d "$dir" ]]; then
        printf 'none'
        return
    fi
    n=$(find -L "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    size=$(du -shL "$dir" 2>/dev/null | awk '{print $1}')
    printf '%s files, %s' "$n" "${size:-0B}"
}

# uninstall_purge_listing <app-support> <config-dir>: print what --purge deletes.
uninstall_purge_listing() {
    local support="$1" config="$2" consent="not present"
    [[ -e "$support/auto_consent.json" ]] && consent="present"
    echo "--purge will permanently delete your own data:"
    printf '  %s/originals/    %s\n' "$support" "$(uninstall_dir_summary "$support/originals")"
    if [[ -d "$support/originals/held" ]]; then
        printf '      of which held-back recordings in held/: %s\n' "$(uninstall_dir_summary "$support/originals/held")"
    fi
    echo "      Kept originals and held-back recordings are in NO backup (not Time Machine, not 'mp backup')."
    printf '  %s/corrections/  %s\n' "$support" "$(uninstall_dir_summary "$support/corrections")"
    printf '  %s/auto_consent.json  %s\n' "$support" "$consent"
    printf '  %s  %s\n' "$config" "$(uninstall_dir_summary "$config")"
}

# uninstall_model_listing <hf-hub-dir> <config.toml>: name and size of each model
# directory the app downloaded, or nothing when there are none.
uninstall_model_listing() {
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        printf '  %s  %s\n' "$dir" "$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    done < <(uninstall_model_dirs "$1" "$2")
}

# uninstall_confirm_purge <assume-yes: 0|1> <app-support> <config-dir> [hf-hub-dir]
#
# Return 0 to go ahead, 1 when declined, 2 when a non-interactive run did not pass --yes.
uninstall_confirm_purge() {
    local yes="$1" answer="" models=""
    uninstall_purge_listing "$2" "$3"
    if [[ -n "${4:-}" ]]; then
        models="$(uninstall_model_listing "$4" "$3/config.toml")"
        if [[ -n "$models" ]]; then
            echo "and the models MeetingPipe downloaded (a later install downloads them again):"
            printf '%s\n' "$models"
        fi
    fi
    if (( yes )); then
        echo "--yes given: not asking."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "Refusing: --purge deletes the data above and there is no terminal to ask on. Re-run in a terminal, or add --yes." >&2
        return 2
    fi
    printf 'Delete all of it? [y/N] '
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}
