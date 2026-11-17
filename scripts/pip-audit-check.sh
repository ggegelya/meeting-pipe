#!/usr/bin/env bash
#
# CI12: fail on any advisory against a package pipeline/uv.lock pins, unless the advisory is on
# scripts/pip-audit-allowlist.txt with a reason. Dependabot was the only advisory mechanism, and
# it opens a PR rather than failing a gate (and its ignore rules hold anthropic, httpx and
# huggingface-hub below their caps, so an advisory fixed only above a cap may get no PR at all).
#
# pip-audit is a tool, not a dependency: it runs through `uvx` at an exact pinned version, so
# nothing is added to uv.lock or the dev extra (owner decision 2026-11-17).
#
# Usage: scripts/pip-audit-check.sh [--requirements FILE] [--allowlist FILE]
#   --requirements  audit this requirements file instead of exporting the lock (for testing)
#   --allowlist     use this allowlist instead of scripts/pip-audit-allowlist.txt
#
# A network failure fails the step with a message naming the network, locally and on CI alike:
# a step that passes when it could not look is the failure mode this exists to close.
set -euo pipefail

PIP_AUDIT_VERSION="2.10.1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
requirements=""
allowlist="$REPO_ROOT/scripts/pip-audit-allowlist.txt"
while [ $# -gt 0 ]; do
    case "$1" in
        --requirements) requirements="$2"; shift 2 ;;
        --allowlist) allowlist="$2"; shift 2 ;;
        *) echo "usage: $0 [--requirements FILE] [--allowlist FILE]" >&2; exit 2 ;;
    esac
done

if ! command -v uvx >/dev/null 2>&1; then
    echo "::error::CI12: uvx not found. Install uv (https://docs.astral.sh/uv/) so the advisory check can run pip-audit $PIP_AUDIT_VERSION."
    exit 1
fi

# The allowlist: `<advisory id> <package> <YYYY-MM-DD> <reason...>`, `#` comments and blank
# lines ignored. A line without a reason is refused, so an exemption always says why.
ignores=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    [ -z "${line//[[:space:]]/}" ] && continue
    read -r id pkg date reason <<<"$line"
    if [ -z "${pkg:-}" ] || [ -z "${reason:-}" ] || ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "::error::CI12: $allowlist:$lineno needs '<advisory id> <package> <YYYY-MM-DD> <reason>'; an exemption with no reason is refused."
        exit 1
    fi
    ignores+=(--ignore-vuln "$id")
done < <([ -f "$allowlist" ] && cat "$allowlist" || true)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -z "$requirements" ]; then
    requirements="$tmp/requirements.txt"
    (cd "$REPO_ROOT/pipeline" && uv export --frozen --all-extras --no-hashes --no-emit-project) > "$requirements"
fi

echo "pip-audit $PIP_AUDIT_VERSION over $(grep -c '==' "$requirements") pinned packages, ${#ignores[@]} allowlist flag(s)"
set +e
uvx "pip-audit==$PIP_AUDIT_VERSION" --no-deps --disable-pip --progress-spinner off --cache-dir "$tmp/cache" \
    -r "$requirements" ${ignores[@]+"${ignores[@]}"} >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
cat "$tmp/out"
if [ "$rc" -eq 0 ]; then
    echo "no known advisories outside the allowlist"; exit 0
fi
if grep -qiE "known vulnerabilit" "$tmp/out" "$tmp/err"; then
    grep -v "hash their pinned\|pip-compile" "$tmp/err" >&2 || true
    echo "::error::CI12: the locked pipeline dependencies carry an advisory. Refresh the lock (SEC31's shape), or add it to scripts/pip-audit-allowlist.txt with the reason it is unreachable."
    exit 1
fi
cat "$tmp/err" >&2
if grep -qiE "connection|network|resolve|timed? ?out|HTTPSConnection|Max retries|ssl" "$tmp/err"; then
    echo "::error::CI12: could not reach the advisory database (network). The check did not run; it fails rather than pass unchecked."
else
    echo "::error::CI12: pip-audit failed for a reason other than an advisory (exit $rc); see above."
fi
exit 1
