#!/usr/bin/env bash
#
# bc-gh/mayhem/build.sh — build gavinhoward/bc's two OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers), AND a normal-flags bc/dc for bc's own test suite (test.sh).
#
# The fuzzed surface is bc's / dc's REAL expression parser + interpreter on attacker-controlled
# program text:
#   bc_fuzzer — src/bc_fuzzer.c: feeds the input as a bc program to bc_main() (lex -> parse -> exec).
#   dc_fuzzer — src/dc_fuzzer.c: feeds the input as a dc program to dc_main() (RPN lex/parse/exec).
# Each harness reads the whole input as one calculator program (NOT a file path) and runs it through
# the same code path the bc/dc binaries use, so the parser/VM (not just a wrapper) is instrumented.
#
# Why we build the fuzzers by hand instead of `./configure -Z && make` (the historical OSS-Fuzz
# build.sh): the current upstream configure.sh no longer carries a `-Z` flag or any fuzzer link rule
# (OSS-Fuzz's bc-gh project is `disabled: true`), so `make all` does NOT produce the *_fuzzer_*
# binaries. We instead: let bc's own configure generate gen/*.c + the Makefile, harvest the exact
# resolved CPPFLAGS from that Makefile (drift-resistant — no hand-copied -D list), flip
# BC_ENABLE_OSSFUZZ on, compile the bc sources + harness, and link against $LIB_FUZZING_ENGINE.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). The bc library code ITSELF is compiled with $SANITIZER_FLAGS so the
# parser/interpreter (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# $SRC is where the repo lives (the org base sets it to the build context root, /mayhem here).
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
export SRC
cd "$SRC"

# ── 0) Generate gen/*.c + the Makefile via bc's own configure (NORMAL flags). This also leaves a
#       working normal-flags bc/dc in bin/ for the test suite (test.sh RUNS it, never compiles). ────
# Use the default cc for the host gen program + the test binaries (clean, un-sanitized — keeps
# test.sh an honest PATCH oracle and avoids sanitizer noise in known-answer diffs).
env -u CFLAGS -u CPPFLAGS ./configure.sh -O2
env -u CFLAGS -u CPPFLAGS make -j"$MAYHEM_JOBS"
echo "built normal bc/dc for the test suite:"; ls -la bin/

# ── 1) Harvest the exact resolved CPPFLAGS from the configured Makefile, then flip OSSFUZZ on. ─────
# (Reading them from the Makefile means we inherit whatever upstream config produced — no stale
# hand-maintained -D list.) Absolute include path so the temp makefile can `include` it from anywhere.
cat > "$SRC/mayhem-printflags.mk" <<EOF
include $SRC/Makefile
__print__:
	@printf '%s' "\$(CPPFLAGS)"
EOF
CPP="$(make -s -C "$SRC" -f "$SRC/mayhem-printflags.mk" __print__)"
rm -f "$SRC/mayhem-printflags.mk"
# Enable the OSS-Fuzz code paths (lex/read skip the stdin/tty machinery; data.c gets the fuzzer args).
CPP="${CPP/-DBC_ENABLE_OSSFUZZ=0/-DBC_ENABLE_OSSFUZZ=1}"

# OSS-Fuzz mode asserts BC_EXPR_EXIT==0 / DC_EXPR_EXIT==0 (the fuzzer drives -e expressions and must
# NOT exit after the first one). Force both defaults off.
CPP="$CPP -DBC_DEFAULT_EXPR_EXIT=0 -DDC_DEFAULT_EXPR_EXIT=0"

# bc's OSSFUZZ block in src/data.c has a _Static_assert that references a non-constant `const size_t`
# (bc_fuzzer_args_len) — illegal in C11+ under clang, but accepted pre-C11. Build the fuzz objects as
# gnu99 (BC_C11=0 -> the asserts are #if'd out; bc fully supports C99, it ships C99 _Noreturn
# fallbacks). This is a build-flag choice only; no upstream source is edited.
STD="-std=gnu99"

# Coverage instrumentation must be on the COMPILED OBJECTS, not just the final link, or libFuzzer
# finds no edges ("no interesting inputs"). fuzzer-no-link adds SanitizerCoverage without pulling in
# the libFuzzer main at object level; the harness link adds the real $LIB_FUZZING_ENGINE main.
COV="-fsanitize=fuzzer-no-link"

read -r -a SAN_ARR <<< "$SANITIZER_FLAGS"
read -r -a CPP_ARR <<< "$CPP"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# ── 2) Compile the bc sources WITH sanitizers + coverage into a library (excluding main.c — the
#       harness provides LLVMFuzzerTestOneInput; library.c is the bcl C-library entry, not needed). ─
OBJS=()
for s in src/*.c; do
  b="$(basename "$s")"
  case "$b" in main.c|library.c|bc_fuzzer.c|dc_fuzzer.c) continue;; esac
  obj="$BUILD/src_${b%.c}.o"
  "$CC" "${SAN_ARR[@]}" "$COV" $STD "${CPP_ARR[@]}" $DEBUG_FLAGS -c "$s" -o "$obj"
  OBJS+=("$obj")
done
# The generated bc-library/help string tables.
for g in gen/lib.c gen/lib2.c gen/bc_help.c gen/dc_help.c; do
  obj="$BUILD/gen_$(basename "${g%.c}").o"
  "$CC" "${SAN_ARR[@]}" "$COV" $STD "${CPP_ARR[@]}" $DEBUG_FLAGS -c "$g" -o "$obj"
  OBJS+=("$obj")
done
LIBBC="$BUILD/libbc_fuzz.a"
rm -f "$LIBBC"; ar rcs "$LIBBC" "${OBJS[@]}"
echo "built sanitized bc object library ($LIBBC, ${#OBJS[@]} objects)"

# Standalone run-once driver from the base (no libFuzzer runtime; reads ONE input file → natural
# crash). Compile it once as an object; it provides main() calling LLVMFuzzerTestOneInput.
STANDALONE_OBJ=""
if [ -n "${STANDALONE_FUZZ_MAIN:-}" ] && [ -f "${STANDALONE_FUZZ_MAIN:-}" ]; then
  STANDALONE_OBJ="$BUILD/standalone_main.o"
  "$CC" "${SAN_ARR[@]}" $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"
fi

# ── 3) Build each harness twice: libFuzzer target (-> /mayhem/<name>) + standalone reproducer. ─────
for h in bc dc; do
  hobj="$BUILD/${h}_fuzzer.o"
  "$CC" "${SAN_ARR[@]}" "$COV" $STD "${CPP_ARR[@]}" $DEBUG_FLAGS -c "src/${h}_fuzzer.c" -o "$hobj"

  # libFuzzer target
  "$CC" "${SAN_ARR[@]}" $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$hobj" "$LIBBC" -lm -o "/mayhem/${h}_fuzzer"

  # standalone reproducer (no libFuzzer runtime)
  if [ -n "$STANDALONE_OBJ" ]; then
    "$CC" "${SAN_ARR[@]}" $DEBUG_FLAGS "$hobj" "$STANDALONE_OBJ" "$LIBBC" -lm -o "/mayhem/${h}_fuzzer-standalone"
  fi
  echo "built ${h}_fuzzer (+ standalone)"
done

echo "build.sh complete:"
ls -la /mayhem/bc_fuzzer /mayhem/dc_fuzzer 2>&1 || true
ls -la /mayhem/bc_fuzzer-standalone /mayhem/dc_fuzzer-standalone 2>&1 || true
