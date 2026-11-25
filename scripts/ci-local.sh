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

# The two color patterns, as variables so the self-test below runs the exact text the checks do.
# HYG18: never `\b`. macOS's ERE has no word boundary, so under Apple Git each `\b` alternative
# matched nothing and the local job was weaker than CI's glibc one; `([^A-Za-z0-9_]|$)` is the
# portable spelling.
END_OF_NAME='([^A-Za-z0-9_]|$)'
DSN3_PATTERN="Color\.(red|orange|green|accentColor)|\.foregroundStyle\(\.(red|orange|green)\)|\.foregroundColor\(\.(red|orange|green)\)|\.accentColor|tint: \.(red|orange|green)$END_OF_NAME|return \.(red|orange|green)$END_OF_NAME"
DSN18_PATTERN="\.foregroundStyle\(\.(secondary|tertiary|quaternary)\)|\.foregroundColor\(\.(secondary|tertiary|quaternary)\)|return \.(secondary|tertiary|quaternary)$END_OF_NAME"

# HYG18: prove each pattern's end-of-name alternatives match on this machine's git grep before
# trusting a clean result. Exact line numbers, so one dead alternative cannot hide behind a live
# one. Run from inside the temp dir: inside the repo, --no-index refuses a path outside it.
pattern_self_test() {
    local probe got rc=0
    probe=$(mktemp -d)
    printf '%s\n' 'tint: .red)' 'return .orange' 'return .secondary' 'return .redder' 'return .secondaryLabel' \
        > "$probe/probe.swift"
    got=$(cd "$probe" && git grep --no-index -nE "$DSN3_PATTERN" -- probe.swift | cut -d: -f2 | tr '\n' ' ' || true)
    if [ "$got" != "1 2 " ]; then
        echo "::error::HYG18: the DSN3 pattern matched probe lines [${got}], expected [1 2 ]. An alternative is dead under this git grep."
        rc=1
    fi
    got=$(cd "$probe" && git grep --no-index -nE "$DSN18_PATTERN" -- probe.swift | cut -d: -f2 | tr '\n' ' ' || true)
    if [ "$got" != "3 " ]; then
        echo "::error::HYG18: the DSN18 pattern matched probe lines [${got}], expected [3 ]. An alternative is dead under this git grep."
        rc=1
    fi
    rm -rf "$probe"
    return "$rc"
}

design_tokens() {
    # TECH-DSN3 / DSN18: enforce the MPColors / MPType design tokens. Colors are a
    # whole-file guard (they were all migrated); fonts are diff-based, since the
    # existing `.system(size:)` literals predate the token ramp and a mass-rewrite
    # would risk sub-pixel shifts and lose Dynamic Type, so only new ones are blocked.
    local matches added base

    begin "Color fence patterns match on this git grep (HYG18)"
    pattern_self_test || return 1
    echo "Every end-of-name alternative matches its probe line, and the near misses do not."
    end

    begin "No raw semantic color literals in daemon UI sources (TECH-DSN3)"
    # The semantic state colors must come from the tokens (.mpDanger / .mpWarning /
    # .mpSuccess / .mpSignal), not the generic system .red/.orange/.green/.accentColor.
    # Tokens.swift is the single allowed source (it defines them plus the speaker palette).
    matches=$(git grep -nE "$DSN3_PATTERN" -- 'daemon/Sources/*.swift' ':!daemon/Sources/MeetingPipe/Design/Tokens.swift' || true)
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
    matches=$(git grep -nE "$DSN18_PATTERN" -- daemon/Sources ':!daemon/Sources/MeetingPipe/Design' || true)
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
    begin "No leftover merge conflict markers"
    # A rebase once left conflict markers in CONVENTIONS.md and every lane still
    # passed, since prose and fixtures compile and parse around them. Only the
    # opening, base and closing markers are matched: a bare ======= line can be
    # legitimate Markdown, and a real conflict always carries both ends.
    local markers
    markers=$(git grep -nIE '^(<{7}|[|]{7}|>{7})( |$)' || true)
    if [ -n "$markers" ]; then
        echo "::error::Merge conflict markers in tracked files. Resolve the conflict before landing."
        echo "$markers"
        return 1
    fi
    echo "No conflict markers in tracked files."
    end

    # CI5: config keys, event categories, CLAUDE.md budgets and doc links match
    # what the code does. Stdlib only, so it needs no environment.
    begin "Truth fences (CI5)"
    python3 scripts/truth_fences.py
    end

    begin "Shell scripts: shellcheck (CI12)"
    # Every tracked shell script at warning severity, taken from git so a new script is covered
    # without editing a list. prune-worktrees.sh deletes directories and install.sh / rebuild.sh
    # touch the keychain and ~/Applications: an unchecked cd or a mistyped variable there is the
    # class of bug that swept a live worktree on 2026-07-24. Missing locally is a failure with the
    # fix named, never a skip; the version is printed so a CI result compares with a local one.
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "::error::CI12: shellcheck not found. Install it with: brew install shellcheck"
        echo "(Linux: apt-get install shellcheck; or put 'uvx --from shellcheck-py shellcheck' on PATH.)"
        return 1
    fi
    shellcheck --version | sed -n 's/^version: /shellcheck /p'
    git ls-files -z -- '*.sh' 'scripts/pre-commit' | xargs -0 shellcheck -S warning
    echo "shellcheck -S warning: $(git ls-files -- '*.sh' 'scripts/pre-commit' | wc -l | tr -d ' ') scripts clean."
    end

    begin "Keychain helper gates (SEC23)"
    bash scripts/test-keychain-migration.sh
    end

    begin "Uninstall keeps the owner's data (DIST8)"
    # The real uninstall.sh against a scratch HOME with stubbed launchctl, pkill,
    # security, tccutil and killall: a plain run keeps originals/ (held/ included),
    # corrections/ and auto_consent.json; --purge lists them and asks first.
    bash scripts/test-uninstall.sh
    end

    begin "Relaunch helper and Swift floor (DIST5)"
    # lib/relaunch.sh, the stop, start and verify install.sh and rebuild.sh share,
    # with launchctl, pkill, pgrep, open and sleep stubbed; the launch-at-login-off
    # branch never bootstraps. Plus the Swift 6.0 floor on canned --version output.
    bash scripts/test-relaunch.sh
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

    begin "no 'never leaves your Mac' promise in the generated plist (STOR6)"
    # The permission prompts install.sh writes into Info.plist are static text macOS shows, so
    # they cannot be derived from the configured backend or library the way the welcome step
    # is. A sentence claiming audio or notes never leave the Mac is false under the default
    # Anthropic engine or a synced library; keep these to what is true under any config.
    if grep -niE "never leaves?( your| this)? mac" scripts/install.sh; then
        echo "::error::STOR6: scripts/install.sh writes a 'never leave(s) your Mac' promise into the app's Info.plist. Say only what is true under every configuration."
        return 1
    fi
    echo "install.sh's permission strings make no never-leaves promise."
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
        begin "Pipeline: dependency advisories (CI12)"
        # pip-audit at a pinned version through uvx over the lock's export, failing on any
        # advisory not in scripts/pip-audit-allowlist.txt. Network is required, as it already is
        # for the install above; an unreachable database fails the step rather than passing it.
        bash ../scripts/pip-audit-check.sh
        end
        begin "Pipeline: ruff"
        # TYPE2: ../scripts too (the generator and the fences import from src/mp, and an
        # unused import there used to pass every gate).
        $run ruff check src tests ../scripts
        end
        begin "Pipeline: pyright (TYPE1, standard since TYPE2)"
        $run pyright
        end
        begin "Pipeline: pytest"
        $run pytest -q
        end
    )
}

# T7: the skips a daemon run may report, one per line as `<Class>` or `<Class>.<method>`, then
# ` | ` and the reason. A skip is a pass to XCTest and to `swift test`'s exit code, so before this
# gate the END10 wiring fence turned itself off on a rename and CI stayed green, and
# FailureProcessTests had never once run in CI. A skip not listed here fails the job. The
# environment entries are listed only when their environment is actually missing.
# WindowRecognizerFixtureTests' "fixture not bundled" skip is deliberately absent: a missing
# fixture is a packaging defect, not an environment (test_recognizer_matches_fixture is not listed,
# so it still fails the gate).
allowed_skips() {
    echo "PlaybackChannelModeTests | AVAudioPCMBuffer allocation guards in its buffer helpers; they never fire on a working CoreAudio stack"
    echo "WindowRecognizerFixtureTests.test_fixture_is_backed_by_real_captures | skipped on purpose until the owner-run Teams title capture lands (VALOWN1, CI6)"
    if ! command -v ffmpeg >/dev/null 2>&1; then
        for class in AudioTranscoderTests MeetingRecorderTests MuteRedactorTests RecordingPostProcessorTests; do
            echo "$class | ffmpeg is not on PATH (CI installs it, so never there)"
        done
    fi
    if [ ! -x "$REPO_ROOT/pipeline/.venv/bin/python3" ]; then
        echo "FailureProcessTests | no pipeline venv: the daemon CI job does not sync one, since the darwin venv pulls the whole mlx stack for one cross-process test (the local \`all\` run syncs it first, so it runs there)"
    fi
}

# Fails when the `swift test` log in $1 reports a skip that `allowed_skips` does not list.
check_skips() {
    local allowed skipped id class unlisted=""
    allowed=$(allowed_skips | sed 's/ | .*//')
    skipped=$(sed -nE "s/^Test Case '-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' skipped.*/\1.\2/p" "$1" | sort -u)
    for id in $skipped; do
        class=${id%%.*}
        if ! printf '%s\n' "$allowed" | grep -qxF -e "$id" -e "$class"; then
            unlisted="$unlisted $id"
        fi
    done
    if [ -n "$unlisted" ]; then
        echo "::error::T7: unlisted test skip(s):$unlisted. A skip reads as a pass, so fix the cause or add the test to allowed_skips in scripts/ci-local.sh with its reason."
        grep -F "Test skipped" "$1" || true
        return 1
    fi
    echo "Skips all allowlisted ($(printf '%s\n' "$skipped" | grep -c . || true) distinct)."
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
        local log
        log=$(mktemp "${TMPDIR:-/tmp}/ci-local-swift-test.XXXXXX")
        swift test 2>&1 | tee "$log"
        end
        begin "Daemon: no unlisted test skips (T7)"
        check_skips "$log"
        rm -f "$log"
        end
        begin "Daemon: engine bounds under a one-thread cooperative pool (CI8)"
        # A blocking call parked on the cooperative pool starves the deadline that is
        # meant to abandon it, and how badly depends on the core count, so the full
        # suite passing on a many-core Mac proves nothing about the 3-core runner.
        # Pinning the pool to one thread makes the starvation deterministic here.
        # The pin goes on the test process alone, never on `swift test`: SwiftPM 6.1 (the
        # macos-15 runner's) deadlocked on its own build graph under the strict pool and sat
        # silent until the 6 h job limit, on every push from 2026-11-12. The suite above has
        # built the bundle, so run it directly, under a 10 minute alarm so a starved deadline
        # fails the job instead of hanging it. SwiftPM 6.1 emits one package bundle, 6.4 one per target.
        local bin bundle
        bin="$(swift build --show-bin-path)"
        bundle="$bin/MeetingPipeTests.xctest"
        [ -d "$bundle" ] || bundle="$bin/MeetingPipePackageTests.xctest"
        LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 perl -e 'alarm shift; exec @ARGV' 600 \
            xcrun xctest -XCTest MeetingPipeTests.EngineTeardownTests,MeetingPipeTests.BoundedEngineStartTests,MeetingPipeTests.RunWithTimeoutTests \
            "$bundle"
        end
        begin "Signing key ACL and hardened runtime (SEC17)"
        # macOS only, so here and not in the Linux fences job. A scratch keychain and a tiny ad-hoc
        # binary: a new dev key is trusted for /usr/bin/codesign alone (a non-Apple process is refused,
        # an -A key allows it), and DYLD_INSERT_LIBRARIES loads into a pre-change signature but not a
        # hardened one. Never touches the login keychain, the real identity or the installed app.
        bash ../scripts/test-dev-cert-acl.sh
        bash ../scripts/test-hardened-runtime.sh
        end
        begin "Rebuild guard: live recording, stop before write, rename (DIST9)"
        # A copy of the real rebuild.sh in a scratch tree with launchctl, pgrep, pkill, open,
        # codesign, swift, uv and mdimport stubbed on PATH. Never the real launchctl or app.
        bash ../scripts/test-rebuild-guard.sh
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

# T9: a suite must leave the owner's real logs folder exactly as it found it. Both suites
# wrote there for months (85 percent of one laptop's pipeline.log was `synthetic frame`
# fixture output), and the only detector was the owner reading the log. Records size and
# mtime of every file under it before a suite and fails if any changed after. Read-only;
# a no-op where the folder does not exist, which is every CI runner. MP_REAL_LOGS_DIR
# exists for the fence's own red check, never to point it somewhere else in normal use.
# A false red is possible if the installed app records or runs a meeting while the suite
# runs: the listing names the file, so re-run when the app was busy.
REAL_LOGS_DIR="${MP_REAL_LOGS_DIR:-$HOME/Library/Logs/MeetingPipe}"
logs_snapshot() {
    [ -d "$REAL_LOGS_DIR" ] || return 0
    find "$REAL_LOGS_DIR" -type f -exec stat -f '%z %m %N' {} + | sort
}
guard_real_logs() {
    local before after
    before="$(logs_snapshot)"
    "$@"
    after="$(logs_snapshot)"
    begin "Real logs folder untouched by $1 (T9)"
    if [ "$before" != "$after" ]; then
        echo "FAIL: the $1 suite changed files under $REAL_LOGS_DIR (size mtime path):" >&2
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
        exit 1
    fi
    end
}

run_job() {
    case "$1" in
        design-tokens) design_tokens ;;
        truth-fences) truth_fences ;;
        pipeline) guard_real_logs pipeline ;;
        daemon) guard_real_logs daemon ;;
        fences) design_tokens; truth_fences ;;
        all) design_tokens; truth_fences; guard_real_logs pipeline; guard_real_logs daemon ;;
        *)
            echo "unknown job: $1 (expected all, fences, design-tokens, truth-fences, pipeline, daemon)" >&2
            exit 2
            ;;
    esac
}

if [ $# -eq 0 ]; then set -- all; fi
for job in "$@"; do run_job "$job"; done
printf '\nci-local: %s green.\n' "$*"
