#!/bin/zsh
# Run the test suite with coverage and fail if NavigatorSyncCore line coverage
# is below the threshold (Requirement 9.5). Default threshold 80%.
set -euo pipefail
THRESHOLD="${1:-80}"

swift test --enable-code-coverage

BIN=$(swift build --show-bin-path)
PROF="$BIN/codecov/default.profdata"
# Find the test bundle binary.
XCTEST=$(find "$BIN" -name '*PackageTests.xctest' -maxdepth 2 | head -1)
if [[ -d "$XCTEST" ]]; then
  TESTBIN="$XCTEST/Contents/MacOS/$(basename "${XCTEST%.xctest}")"
else
  TESTBIN="$XCTEST"
fi

PCT=$(xcrun llvm-cov report "$TESTBIN" \
  -instr-profile "$PROF" \
  -ignore-filename-regex='(Tests|\.build)/' \
  2>/dev/null | awk '/NavigatorSyncCore/ {f=1} END {} f && /TOTAL/ {print $10}' | tr -d '%')

# Fallback: TOTAL line of the whole report.
if [[ -z "${PCT:-}" ]]; then
  PCT=$(xcrun llvm-cov report "$TESTBIN" -instr-profile "$PROF" \
    -ignore-filename-regex='(Tests|\.build)/' 2>/dev/null \
    | awk '/^TOTAL/ {print $10}' | tr -d '%')
fi

echo "NavigatorSyncCore line coverage: ${PCT:-unknown}% (threshold ${THRESHOLD}%)"
if [[ -z "${PCT:-}" ]]; then
  echo "could not determine coverage" >&2; exit 2
fi
# Integer compare (coverage reported to 2dp; compare the integer part).
if (( ${PCT%.*} < THRESHOLD )); then
  echo "FAIL: coverage below ${THRESHOLD}%" >&2; exit 1
fi
echo "OK: coverage meets threshold"
