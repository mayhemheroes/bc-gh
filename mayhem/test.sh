#!/usr/bin/env bash
#
# bc-gh/mayhem/test.sh — RUN gavinhoward/bc's own test suite (against the normal-flags bin/bc and
# bin/dc that mayhem/build.sh produced) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: bc's suite is a large KNOWN-ANSWER / golden-output suite. tests/all.sh feeds
# each committed tests/{bc,dc}/*.txt program to bin/bc / bin/dc and diffs the actual output against
# the committed *_results.txt expected output, plus tests/{bc,dc}/errors/* which assert the EXACT
# error behavior (exit status + message). A mismatch makes the runner FAIL!!! and err_exit non-zero.
# Verified: a binary that prints the wrong answer fails this oracle — so a no-op / "exit(0)" patch
# (or any change that alters computed output) CANNOT pass. This script only RUNS the pre-built
# binaries; it never compiles.
#
# We run with generate_tests=0 (the 4th all.sh arg) on purpose:
#   * the script-`print` tests would otherwise shell out to a SYSTEM `bc` to generate golden output,
#     which is absent in the base image (and self-comparison would be an invalid oracle anyway);
#   * with gen=0 those uncommitted-result cases are SKIPPED, and only the committed expected-output
#     comparisons run — a self-contained, honest KAT subset (hundreds of cases incl. all error tests).
# We also use the non-parallel runner (-n): the parallel path calls `jobs -r`, which the base's
# POSIX `sh` (dash) rejects; serial is deterministic.
set -uo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$SRC/bin/bc" ]; then
  echo "missing $SRC/bin/bc — run mayhem/build.sh first" >&2
  emit_ctrf "bc-tests" 0 1 0; exit 2
fi

# Resolve BC_ENABLE_EXTRA_MATH from the configured Makefile so the test args match the build config.
EXTRA=1
if [ -f "$SRC/Makefile" ]; then
  cat > "$SRC/mayhem-testflags.mk" <<EOF
include $SRC/Makefile
__p__:
	@printf '%s' "\$(BC_ENABLE_EXTRA_MATH)"
EOF
  EXTRA="$(make -s -C "$SRC" -f "$SRC/mayhem-testflags.mk" __p__ 2>/dev/null || echo 1)"
  rm -f "$SRC/mayhem-testflags.mk"
  [ -n "$EXTRA" ] || EXTRA=1
fi

TOTAL_PASS=0 TOTAL_FAIL=0 TOTAL_SKIP=0
run_suite() {
  local d="$1" exe="$2"
  echo "=== running $d test suite (tests/all.sh -n $d $EXTRA 1 0 0) ==="
  # args: [-n] dir extra_math run_stack_tests generate_tests run_problematic_tests exe
  local out rc
  out="$(sh "$SRC/tests/all.sh" -n "$d" "$EXTRA" 1 0 0 "$exe" 2>&1)"; rc=$?
  echo "$out"
  local p s
  p=$(printf '%s\n' "$out" | grep -Ec 'pass$' || true)
  s=$(printf '%s\n' "$out" | grep -c 'Skipping' || true)
  TOTAL_PASS=$(( TOTAL_PASS + p ))
  TOTAL_SKIP=$(( TOTAL_SKIP + s ))
  if [ "$rc" -ne 0 ]; then
    local f
    f=$(printf '%s\n' "$out" | grep -c 'FAIL' || true)
    [ "$f" -gt 0 ] || f=1
    TOTAL_FAIL=$(( TOTAL_FAIL + f ))
  fi
}

run_suite bc "$SRC/bin/bc"
run_suite dc "$SRC/bin/dc"

[ "$TOTAL_PASS" -gt 0 ] || { [ "$TOTAL_FAIL" -gt 0 ] || TOTAL_FAIL=1; }
emit_ctrf "bc-tests" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
