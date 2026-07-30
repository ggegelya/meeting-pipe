#!/usr/bin/env bash
# Gate matrix for the launch-at-login guard in scripts/lib/login-agent.sh.
#
# That guard is what makes install.sh and rebuild.sh respect a launch-at-login
# toggle the owner turned off (UX42). It is a text predicate over
# `launchctl print-disabled` output on purpose, so this file can pin the
# install-over-a-disabled-agent case against canned output instead of mutating
# the machine's real login item to test it.
#
# Reads nothing, writes nothing, and never invokes launchctl. One line per case;
# exits non-zero if any case fails.

set -u

# shellcheck source=scripts/lib/login-agent.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/login-agent.sh"

LABEL="com.meetingpipe.daemon"
failures=0

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# expect_disabled <name> <output>
expect_disabled() {
    if login_agent_disabled_in_output "$2" "$LABEL"; then ok "$1"; else fail "$1"; fi
}
# expect_armed <name> <output>
expect_armed() {
    if login_agent_disabled_in_output "$2" "$LABEL"; then fail "$1"; else ok "$1"; fi
}

# The real shape: tab-indented entries inside a `disabled services = {}` block.
disabled_block=$'disabled services = {\n\t\t"com.docker.helper" => enabled\n\t\t"com.meetingpipe.daemon" => disabled\n\t\t"com.apple.Siri.agent" => disabled\n}'
enabled_block=$'disabled services = {\n\t\t"com.docker.helper" => enabled\n\t\t"com.meetingpipe.daemon" => enabled\n\t\t"com.apple.Siri.agent" => disabled\n}'
absent_block=$'disabled services = {\n\t\t"com.docker.helper" => enabled\n\t\t"com.apple.Siri.agent" => disabled\n}'

# THE CASE THE ACCEPTANCE ASKS FOR: an install over a disabled agent must see it
# as disabled, so it bootstraps nothing and leaves the override alone.
expect_disabled "disabled override is seen"                 "$disabled_block"
expect_armed    "explicit enabled override is not disabled" "$enabled_block"

# No line at all is launchd's "no override", which means the plist wins, and our
# plist carries RunAtLoad=true. Reading that as disabled would silently stop
# every fresh install from ever starting the daemon.
expect_armed    "a label with no override line is armed"    "$absent_block"
expect_armed    "empty output is armed"                     ""

# A sibling label that merely starts with ours must not match, which is why the
# predicate quotes the label rather than substring-matching it. Both halves: a
# disabled sibling must not disable us, and a disabled us must still be found
# next to an enabled sibling.
expect_armed    "a disabled sibling label does not match" \
    $'\t\t"com.meetingpipe.daemon.helper" => disabled'
expect_disabled "our label is found beside an enabled sibling" \
    $'\t\t"com.meetingpipe.daemon.helper" => enabled\n\t\t"com.meetingpipe.daemon" => disabled'

# Spacing around the arrow is launchctl's to choose, not ours to depend on.
expect_disabled "extra spacing around the arrow still matches" \
    '        "com.meetingpipe.daemon"   =>   disabled   '

# A truncated or garbled line is not a disable. A guard that fails open here
# would leave the daemon unloaded after an install, with no error anywhere.
expect_armed    "a label line with no verdict is armed" \
    $'\t\t"com.meetingpipe.daemon" =>'
expect_armed    "a bare label line is armed" \
    $'\t\t"com.meetingpipe.daemon"'

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'all cases passed\n'
else
    printf '%s case(s) failed\n' "$failures"
fi
exit "$failures"
