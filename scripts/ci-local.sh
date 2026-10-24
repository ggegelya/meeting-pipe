#!/usr/bin/env bash
#
# CI8: the CI step list, as one script that runs the same here and on GitHub.
#
# .github/workflows/ci.yml calls this for every job, after only that job's own
# setup (checkout, uv, ffmpeg), so what passes here is what CI runs. That is the
# whole point. CI on main went red on 2026-07-31 and stayed red for 82 days
# while every local gate stayed green, because the two ran different commands: CI floated
# its Python deps while local resolved from uv.lock, local never ran the design
# token greps, and local `swift test` had more cores than the runner. Pushes are
# rare, so nobody saw it. Add a CI step HERE, never only in the YAML.
#
# Usage:
#   scripts/ci-local.sh                 # every job, in CI's order
#   scripts/ci-local.sh pipeline        # one job
#   scripts/ci-local.sh fences          # design-tokens + truth-fences (docs-only change)
#
# Jobs: design-tokens, truth-fences, pipeline, daemon. Fails fast on the first
# red step. Needs uv, python3, and (for daemon) full Xcode plus ffmpeg on PATH.
#
# BEFORE: the base the font-size check diffs against. CI sets it from the push
# or pull-request event (empty on a scheduled or manual run, which skips the
# check). Unset locally, it defaults to origin/main, which is what the next push
# will be checked against.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# GitHub folds ::group:: blocks in the log; a terminal gets a plain header.
begin() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$1"; else printf '\n==> %s\n' "$1"; fi
}
end() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
}

design_tokens() {
    # TECH-DSN3 / DSN18: enforce the MPColors / MPType design tokens. Colors are a
    # whole-file guard (they were all migrated); fonts are diff-based, since the
    # existing `.system(size:)` literals predate the token ramp and a mass-rewrite
    # would risk sub-pixel shifts and lose Dynamic Type, so only new ones are blocked.
    local matches added base

    begin "No raw semantic color literals in daemon UI sources (TECH-DSN3)"
    # The semantic state colors must come from the tokens (.mpDanger / .mpWarning /
    # .mpSuccess / .mpSignal), not the generic system .red/.orange/.green/.accentColor.
    # Tokens.swift is the single allowed source (it defines them plus the speaker palette).
    matches=$(git grep -nE 'Color\.(red|orange|green|accentColor)|\.foregroundStyle\(\.(red|orange|green)\)|\.foregroundColor\(\.(red|orange|green)\)|\.accentColor|tint: \.(red|orange|green)\b|return \.(red|orange|green)\b' -- 'daemon/Sources/*.swift' ':!daemon/Sources/MeetingPipe/Design/Tokens.swift' || true)
    if [ -n "$matches" ]; then
        echo "::error::TECH-DSN3: raw semantic color literal under daemon/Sources. Use the token (.mpDanger / .mpWarning / .mpSuccess / .mpSignal)."
        echo "$matches"
        return 1
    fi
    echo "No raw semantic color literals."
    end

    begin "No bare native-semantic text colors (TECH-DSN18)"
    # Native .secondary/.tertiary/.quaternary fail WCAG as text on paper (.tertiary
    # ~1.88:1, .secondary ~3.94:1). Text foregrounds must come from the
    # legibility-checked tokens (fgMuted / fgSubtle), whose floor ContrastFloorTests
    # pins. Recursive scope on purpose; Design/ is the allowed definition site.
    # Color.secondary.opacity(...) fills and borders are out of scope (not text).
    matches=$(git grep -nE '\.foregroundStyle\(\.(secondary|tertiary|quaternary)\)|\.foregroundColor\(\.(secondary|tertiary|quaternary)\)|return \.(secondary|tertiary|quaternary)\b' -- daemon/Sources ':!daemon/Sources/MeetingPipe/Design' || true)
    if [ -n "$matches" ]; then
        echo "::error::TECH-DSN18: bare native-semantic text color under daemon/Sources. Use a token (Color(MPColors.fgMuted) for secondary, Color(MPColors.fgSubtle) for tertiary)."
        echo "$matches"
        return 1
    fi
    echo "No bare native-semantic text colors."
    end

    begin "No newly-introduced raw font-size literals (TECH-DSN3)"
    # Diff-based: only fail on a NEW `.system(size:)` a change adds. Prefer
    # MPType.textXX for the size, or a Dynamic-Type font (.caption, .headline)
    # where scaling matters. `[+]` rather than `\+`: BSD grep rejects `^\+\+\+`,
    # and the `|| true` below turned that error into a silent pass on macOS.
    if [ -n "${BEFORE+set}" ]; then
        base="$BEFORE"
    else
        base=$(git rev-parse --verify --quiet origin/main || true)
    fi
    if [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ]; then
        echo "No base SHA (first push, shallow clone, scheduled run, or no origin/main) - skipping diff check."
    else
        added=$(git diff --unified=0 "$base"...HEAD -- 'daemon/Sources/*.swift' ':!daemon/Sources/MeetingPipe/Design/Tokens.swift' \
            | grep -E '^[+]' | grep -v '^[+][+][+]' || true)
        if echo "$added" | grep -F '.system(size:' >/dev/null; then
            echo "::error::TECH-DSN3: new raw .system(size:) font literal. Use MPType.textXX for the size, or a Dynamic-Type font where scaling matters."
            echo "$added" | grep -nF '.system(size:'
            return 1
        fi
        echo "No newly-introduced raw font-size literals."
    fi
    end
}

truth_fences() {
    # CI5: config keys, event categories, CLAUDE.md budgets and doc links match
    # what the code does. Stdlib only, so it needs no environment.
    begin "Truth fences (CI5)"
    python3 scripts/truth_fences.py
    end

    begin "macOS floor parity (DOC16)"
    # The floor is written three times: Package.swift's platforms, install.sh's
    # version check, and the LSMinimumSystemVersion install.sh writes into the
    # app's Info.plist. The plist read 13.0 against a macOS 14 package until
    # DOC16, so Finder would have launched a copied app on 13. Plain sed, since
    # this job runs on Linux too.
    local pkg plist check
    pkg=$(sed -n 's/.*platforms: *\[\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' daemon/Package.swift)
    plist=$(grep -A1 '<key>LSMinimumSystemVersion</key>' scripts/install.sh | sed -n 's/.*<string>\([0-9][0-9]*\)\.0<\/string>.*/\1/p')
    check=$(sed -n 's/.*(( *SW_MAJOR < \([0-9][0-9]*\) *)).*/\1/p' scripts/install.sh)
    if [ -z "$pkg" ] || [ -z "$plist" ] || [ -z "$check" ] || [ "$pkg" != "$plist" ] || [ "$pkg" != "$check" ]; then
        echo "::error::DOC16: macOS floor disagrees (or could not be read). Package.swift .macOS(.v${pkg:-?}), install.sh LSMinimumSystemVersion ${plist:-?}.0, install.sh SW_MAJOR check ${check:-?}."
        return 1
    fi
    echo "macOS $pkg everywhere: Package.swift, install.sh check, LSMinimumSystemVersion."
    end
}

pipeline() {
    # From uv.lock, the set every local `uv run` uses. The darwin/arm64-only mlx
    # stack carries platform markers, so the Linux runner skips it.
    local run="uv run --frozen --extra dev --extra mcp"
    (
        cd pipeline
        begin "Pipeline: install from the lock"
        uv sync --frozen --extra dev --extra mcp
        end
        begin "Pipeline: ruff"
        $run ruff check src tests
        end
        begin "Pipeline: pyright (TYPE1)"
        $run pyright
        end
        begin "Pipeline: pytest"
        $run pytest -q
        end
    )
}

daemon() {
    (
        cd daemon
        begin "Daemon: swift build"
        swift build
        end
        begin "Daemon: swift test"
        # The MuteRedactor data-safety tests shell out to ffmpeg; without it on PATH
        # they skip and the most destructive path goes unverified.
        command -v ffmpeg >/dev/null 2>&1 || echo "WARNING: ffmpeg not on PATH; the MuteRedactor tests will skip."
        swift test
        end
        begin "Daemon: engine bounds under a one-thread cooperative pool (CI8)"
        # A blocking call parked on the cooperative pool starves the deadline that is
        # meant to abandon it, and how badly depends on the core count, so the full
        # suite passing on a many-core Mac proves nothing about the 3-core runner.
        # Pinning the pool to one thread makes the starvation deterministic here.
        LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter 'EngineTeardownTests|BoundedEngineStartTests|RunWithTimeoutTests'
        end
        begin "Daemon: installed-app relocation smoke (DIST4)"
        # Assembles a staging MeetingPipe.app from the debug build above with the
        # installer's own functions, moves daemon/.build aside, and runs the staged
        # `MeetingPipe doctor`: it must not crash, and must load its resource
        # bundles from Contents/Resources rather than the build tree. Without
        # --with-pipeline: that half syncs the app's full venv, mlx stack included,
        # which is a download this job does not need for what it fences.
        bash ../scripts/test-app-relocation.sh .build/debug
        end
    )
}

run_job() {
    case "$1" in
        design-tokens) design_tokens ;;
        truth-fences) truth_fences ;;
        pipeline) pipeline ;;
        daemon) daemon ;;
        fences) design_tokens; truth_fences ;;
        all) design_tokens; truth_fences; pipeline; daemon ;;
        *)
            echo "unknown job: $1 (expected all, fences, design-tokens, truth-fences, pipeline, daemon)" >&2
            exit 2
            ;;
    esac
}

if [ $# -eq 0 ]; then set -- all; fi
for job in "$@"; do run_job "$job"; done
printf '\nci-local: %s green.\n' "$*"
