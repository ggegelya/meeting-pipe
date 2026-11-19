#!/usr/bin/env bash
# T3: line coverage for both trees, in one command.
#
# Neither tree measured coverage before this: pytest-cov was absent from the dev
# extras and `--enable-code-coverage` appeared nowhere, so "is this tested" was
# answered by grepping for a type name. This prints per-module numbers so the
# untested surface is a number you can watch move.
#
# It is a REPORT, not a gate. No threshold is enforced and CI does not run it;
# a ratchet is a separate decision from being able to see the number.
#
#   ./scripts/coverage.sh            both trees
#   ./scripts/coverage.sh python     pipeline only
#   ./scripts/coverage.sh swift      daemon only
#
# The daemon leg needs full Xcode (`swift test` errors on `import XCTest` under
# Command Line Tools alone); it says so and skips rather than failing the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHICH="${1:-both}"

hr() { printf '%s\n' "------------------------------------------------------------"; }

run_python() {
  hr; echo "PIPELINE (pytest-cov over src/mp)"; hr
  cd "$ROOT/pipeline"
  # `--cov-report=term-missing:skip-covered` keeps the table to the modules that
  # actually have uncovered lines, which is the list worth reading.
  uv run --extra dev pytest -q \
    --cov=mp \
    --cov-report=term-missing:skip-covered \
    --cov-report="html:$ROOT/.coverage-html/pipeline" \
    "${@:2}"
  echo
  echo "HTML: $ROOT/.coverage-html/pipeline/index.html"
}

run_swift() {
  hr; echo "DAEMON (swift test --enable-code-coverage)"; hr
  cd "$ROOT/daemon"

  if ! xcrun --find llvm-cov >/dev/null 2>&1; then
    echo "SKIP: llvm-cov not found. The daemon leg needs full Xcode:"
    echo "      sudo xcode-select -s /Applications/Xcode.app"
    return 0
  fi

  swift test --enable-code-coverage

  # T16: look only in the products directory this toolchain reports. It used to
  # take the first `find .build ... -print -quit` hit, and the toolchain now
  # builds one bundle per test target (MeetingPipeCoreTests, MeetingPipeTests)
  # while an older layout's combined MeetingPipePackageTests bundle can linger in
  # `.build/arm64-apple-macosx`. Directory order then decided which single bundle
  # was measured: one run printed 90.0% (the Core bundle alone) for a daemon
  # whose main bundle reads 51.0%, and another picked the stale bundle, which
  # has no profile data at all.
  local bindir profdata
  bindir="$(swift build --show-bin-path 2>/dev/null)" || bindir=""
  if [ -z "$bindir" ] || [ ! -d "$bindir" ]; then
    echo "SKIP: could not resolve the products directory (swift build --show-bin-path)."
    return 0
  fi

  # `swift test --show-codecov-path` points at the JSON export; llvm-cov wants
  # the profdata, which sits in the products directory's codecov/.
  profdata="$bindir/codecov/default.profdata"
  if [ ! -f "$profdata" ]; then
    echo "SKIP: no default.profdata produced."
    return 0
  fi

  # Every test bundle, so the table and the headline cover their union.
  # `-not -path '*.dSYM/*'` matters: the debug bundle nests under the same
  # `.xctest/Contents/MacOS/` path, and llvm-cov rejects its relocations YAML
  # with a confusing "not a valid object file". Sorted, so the first binary (the
  # positional one) is the same every run.
  local bins=() b
  while IFS= read -r -d '' b; do
    bins+=("$b")
  done < <(find "$bindir" -maxdepth 4 -type f -path '*.xctest/Contents/MacOS/*' \
             -not -path '*.dSYM/*' -print0 | sort -z)
  if [ "${#bins[@]}" -eq 0 ]; then
    echo "SKIP: could not locate any xctest binary under $bindir."
    return 0
  fi

  # llvm-cov takes the first object positionally and every other with -object.
  local objects=("${bins[0]}")
  for b in "${bins[@]:1}"; do
    objects+=(-object "$b")
  done

  echo
  echo "Measured bundles (merged):"
  for b in "${bins[@]}"; do
    echo "  $(basename "$b")"
  done

  echo
  # Report only our own sources: the SPM checkouts (FluidAudio, TOMLKit, ...)
  # and the test targets themselves would otherwise dominate the table.
  xcrun llvm-cov report "${objects[@]}" \
    -instr-profile "$profdata" \
    -ignore-filename-regex='(\.build|Tests)/' \
    | sed -e 's|.*/Sources/|Sources/|'

  # The table above has four `Cover` columns (region / function / line / branch)
  # and it is easy to read the wrong one, so restate the line number plainly.
  echo
  # The reader below binds the three numbers before formatting them. The obvious
  # `{totals["covered"]}` cannot be written inline: the program is a single-quoted
  # shell word, so a nested `"` has to be escaped, and a backslash inside an
  # f-string expression is a SyntaxError. That was CI6 item 1, and it exited 1 on
  # every run of this leg from f78ca057 (2026-07-20) until it was fixed.
  xcrun llvm-cov export "${objects[@]}" \
    -instr-profile "$profdata" \
    -ignore-filename-regex='(\.build|Tests)/' \
    -summary-only 2>/dev/null \
  | python3 -c '
import json, sys
totals = json.load(sys.stdin)["data"][0]["totals"]["lines"]
covered, count, percent = totals["covered"], totals["count"], totals["percent"]
print(f"LINE COVERAGE: {covered}/{count} = {percent:.1f}%")
'
}

case "$WHICH" in
  python|py|pipeline) run_python "$@" ;;
  swift|daemon)       run_swift ;;
  both)               run_python "$@"; echo; run_swift ;;
  *) echo "usage: $0 [both|python|swift]" >&2; exit 2 ;;
esac
