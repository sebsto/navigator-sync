#!/bin/zsh
# Run the test suite with coverage and fail if NavigatorSyncCore line coverage
# is below the threshold (Requirement 9.5). Default threshold 80%.
#
# Coverage is measured only over Sources/NavigatorSyncCore (the library under
# test); test files and the swift-subprocess dependency are excluded.
set -euo pipefail
THRESHOLD="${1:-80}"

swift test --enable-code-coverage

BIN=$(swift build --show-bin-path)
PROF="$BIN/codecov/default.profdata"
XCTEST=$(find "$BIN" -name '*.xctest' | head -1)
TESTBIN="$XCTEST/Contents/MacOS/$(basename "${XCTEST%.xctest}")"

PCT=$(xcrun llvm-cov report "$TESTBIN" -instr-profile "$PROF" 2>/dev/null \
  | awk '/Sources\/NavigatorSyncCore\// {tot+=$8; miss+=$9}
         END { if (tot > 0) printf "%.2f", (tot-miss)*100.0/tot; else print "" }')

echo "NavigatorSyncCore line coverage: ${PCT:-unknown}% (threshold ${THRESHOLD}%)"
if [[ -z "${PCT:-}" ]]; then
  echo "could not determine coverage" >&2; exit 2
fi
if (( ${PCT%.*} < THRESHOLD )); then
  echo "FAIL: coverage below ${THRESHOLD}%" >&2; exit 1
fi
echo "OK: coverage meets threshold"
