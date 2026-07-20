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

  local profdata bin
  # `swift test --show-codecov-path` points at the JSON export; llvm-cov wants
  # the profdata, which sits beside the build products.
  profdata="$(find .build -name 'default.profdata' -print -quit)"
  if [ -z "$profdata" ]; then
    echo "SKIP: no default.profdata produced."
    return 0
  fi

  # `-not -path '*.dSYM/*'` matters: the debug bundle nests under the same
  # `.xctest/Contents/MacOS/` path, and llvm-cov rejects its relocations YAML
  # with a confusing "not a valid object file".
  bin="$(find .build -type f -path '*.xctest/Contents/MacOS/*' -not -path '*.dSYM/*' -print -quit)"
  if [ -z "$bin" ]; then
    echo "SKIP: could not locate the xctest binary."
    return 0
  fi

  echo
  # Report only our own sources: the SPM checkouts (FluidAudio, TOMLKit, ...)
  # and the test targets themselves would otherwise dominate the table.
  xcrun llvm-cov report "$bin" \
    -instr-profile "$profdata" \
    -ignore-filename-regex='(\.build|Tests)/' \
    | sed -e 's|.*/Sources/|Sources/|'

  # The table above has four `Cover` columns (region / function / line / branch)
  # and it is easy to read the wrong one, so restate the line number plainly.
  echo
  xcrun llvm-cov export "$bin" \
    -instr-profile "$profdata" \
    -ignore-filename-regex='(\.build|Tests)/' \
    -summary-only 2>/dev/null \
  | python3 -c '
import json, sys
totals = json.load(sys.stdin)["data"][0]["totals"]["lines"]
print(f"LINE COVERAGE: {totals[\"covered\"]}/{totals[\"count\"]} = {totals[\"percent\"]:.1f}%")
'
}

case "$WHICH" in
  python|py|pipeline) run_python "$@" ;;
  swift|daemon)       run_swift ;;
  both)               run_python "$@"; echo; run_swift ;;
  *) echo "usage: $0 [both|python|swift]" >&2; exit 2 ;;
esac
