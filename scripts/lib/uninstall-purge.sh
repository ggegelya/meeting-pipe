#!/usr/bin/env bash
# The purge gate for scripts/uninstall.sh (DIST8). Sourced, not run.
#
# A plain uninstall keeps ~/Library/Application Support/MeetingPipe because it
# holds things nothing else has: originals/ (the only copy of a held-back or
# quarantined recording, in no backup and no Time Machine, ADR 0016; SEC26's
# held/ folder sits under it), corrections/ (the summary-grading corpus, which
# exists nowhere else) and auto_consent.json. --purge is the one way to delete
# them, so it lists what is about to go and asks first.

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

# uninstall_confirm_purge <assume-yes: 0|1> <app-support> <config-dir>
#
# Return 0 to go ahead, 1 when declined, 2 when a non-interactive run did not pass --yes.
uninstall_confirm_purge() {
    local yes="$1" answer=""
    uninstall_purge_listing "$2" "$3"
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
