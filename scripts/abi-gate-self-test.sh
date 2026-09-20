#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
#
# abi-gate-self-test.sh — break the ABI three ways and require every gate to notice.
#
#   bash scripts/abi-gate-self-test.sh
#
# The rule this exists for (scripts/check-proofs.sh states it, and it is the one
# that matters): a gate is not "a check that passes", it is "a check you have
# WATCHED FAIL". `just abi-check` passing proves very little on its own — a script
# that always exits 0 passes too. So this script performs three deliberate
# breakages, each in a scratch copy, and requires the corresponding gate to fail
# for the RIGHT reason:
#
#   1. THE MODEL vs THE PROOFS. Widen a field in Abi/Types.idr so the declared
#      fields no longer match the proven size list. `Abi.Gen` must refuse to write
#      and must say which struct disagreed — not emit a header and hope.
#   2. THE HEADER vs THE C COMPILER. Edit one EE_OFFSET_* define by hand in the
#      generated header. The C compiler's _Static_assert must reject it, which is
#      the layer that catches a hand-edited header a host would otherwise compile
#      against happily.
#   3. THE ZIG VIEW vs THE SAME NUMBERS. Edit one offset constant in
#      ee_layout.zig. The Zig build must fail at comptime, because the kernel's
#      structs are checked against that file before any code runs.
#
# Each experiment asserts BOTH that the gate fails AND that nothing was written to
# the real tree: the scratch copies are the only thing modified, and the script
# verifies that by checksumming the real artefacts before and after.
#
# Exit: 0 = all three gates failed as required; 1 = a gate missed a breakage (or a
# toolchain is missing — this never skips); 2 = misuse.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

for tool in idris2 zig gcc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: '$tool' is not on PATH." >&2
        echo "      Run: bash scripts/install-toolchain.sh" >&2
        exit 1
    fi
done

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
report() {
    # report <ok:0|1> <description>
    if [ "$1" -eq 0 ]; then
        echo "  PASS: $2"
        pass=$((pass + 1))
    else
        echo "  FAIL: $2"
        fail=$((fail + 1))
    fi
}

echo "=== ABI gate self-test — every gate must fail when the ABI is broken ==="
echo

# Something to compare against at the end: if any of these change, a self-test
# touched the real tree, which is a bug in the self-test rather than a finding.
before="$(sha256sum include/evil_weevil/ee.h src/interface/generated/ee_layout.zig)"

scratch_repo() {
    # A copy of the tracked tree, without build outputs, so a scratch experiment
    # cannot be influenced by (or pollute) a previous one.
    local dest="$1"
    mkdir -p "$dest"
    tar --exclude='./.git' --exclude='./_build' --exclude='*/zig-out' \
        --exclude='*/.zig-cache' -cf - . | tar -xf - -C "$dest"
}

# ── 1. The model and the proofs must disagree loudly ─────────────────────────
echo "1. widening a field in the model must make the generator refuse to write"
one="$SCRATCH/one"
scratch_repo "$one"
# `struct_size: u32` (ee_init_desc's first field) becomes u64: the declared fields
# now disagree with the proven size list, which is precisely the cross-check.
python3 - "$one/src/interface/Abi/Types.idr" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# struct_size is u32 in the model and in the proven size list for ee_init_desc.
# Widening it to u64 leaves the declared fields and the proofs disagreeing about
# the first struct in the ABI, which is what the cross-check exists to catch.
old = '  [ ("struct_size", U32)'
assert old in s, "fixture moved: ee_init_desc.struct_size is no longer U32 in Types.idr"
s = s.replace(old, '  [ ("struct_size", U64)', 1)
open(p, 'w').write(s)
PY
# Whether it wrote anything is a question about CONTENT, not existence: the copy
# already contains the committed header, so `-f` would always be true and the check
# would be vacuous. (It was, in the first draft of this script — which is the whole
# argument for watching a gate fail instead of reading it.)
one_before="$(sha256sum "$one/include/evil_weevil/ee.h" | cut -d' ' -f1)"
gen_log="$SCRATCH/one.log"
set +e
( cd "$one" && idris2 --source-dir src/interface --build-dir _build/idris2 -o ee-abi-gen src/interface/Abi/Gen.idr >/dev/null 2>&1 \
    && ./_build/idris2/exec/ee-abi-gen "$one" ) > "$gen_log" 2>&1
gen_rc=$?
set -e
if [ "$gen_rc" -eq 0 ]; then
    report 1 "generator exited 0 on a model/proof mismatch — it should have refused"
else
    if grep -qiE "mismatch|disagree|refus|not match" "$gen_log"; then
        report 0 "generator refused and named the problem: $(head -1 "$gen_log" | cut -c1-100)"
    else
        report 1 "generator failed for an unexplained reason (expected a mismatch report):
$(sed 's/^/        /' "$gen_log" | head -5)"
    fi
fi
one_after="$(sha256sum "$one/include/evil_weevil/ee.h" | cut -d' ' -f1)"
if [ "$one_before" = "$one_after" ]; then
    report 0 "the refusal wrote nothing — the header is byte-identical to the committed one"
else
    report 1 "a refused generation still modified the header — the refusal is not a refusal"
fi
echo

# ── 2. A hand-edited header must be caught by the C compiler ─────────────────
echo "2. a hand-edited offset define must fail the header's _Static_asserts"
two="$SCRATCH/two"
scratch_repo "$two"
python3 - "$two/include/evil_weevil/ee.h" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# One byte off, in a define that a host would silently compile against.
import re
m = re.search(r'#define EE_OFFSET_ee_snapshot_tick (\d+)', s)
assert m, "fixture moved: no EE_OFFSET_ee_snapshot_tick define"
s = s.replace(m.group(0), '#define EE_OFFSET_ee_snapshot_tick %d' % (int(m.group(1)) + 1), 1)
open(p, 'w').write(s)
PY
set +e
gcc -std=c11 -Wall -Wextra -Werror -I"$two/include" -c tests/host/null_host.c -o "$SCRATCH/two.o" > "$SCRATCH/two.log" 2>&1
two_rc=$?
set -e
if [ "$two_rc" -ne 0 ] && grep -qi "static assertion\|_Static_assert" "$SCRATCH/two.log"; then
    msg="$(grep -m1 -i "static assertion failed" "$SCRATCH/two.log" | cut -c1-90 || true)"
    report 0 "the C compiler rejected it: ${msg:-_Static_assert fired}"
elif [ "$two_rc" -ne 0 ]; then
    report 1 "compilation failed, but not on a static assertion:
$(sed 's/^/        /' "$SCRATCH/two.log" | head -5)"
else
    report 1 "a header with a wrong offset compiled cleanly — the C layer is not checking"
fi
echo

# ── 3. A stale Zig view must fail the build, at comptime ─────────────────────
echo "3. a hand-edited Zig offset must fail the kernel build at comptime"
three="$SCRATCH/three"
scratch_repo "$three"
python3 - "$three/src/interface/generated/ee_layout.zig" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r'pub const offset_ee_snapshot_tick: usize = (\d+);', s)
assert m, "fixture moved: no offset_ee_snapshot_tick constant"
s = s.replace(m.group(0), 'pub const offset_ee_snapshot_tick: usize = %d;' % (int(m.group(1)) + 1), 1)
open(p, 'w').write(s)
PY
set +e
( cd "$three" && zig build --build-file src/interface/ffi/build.zig ) > "$SCRATCH/three.log" 2>&1
three_rc=$?
set -e
if [ "$three_rc" -ne 0 ] && grep -q "ABI drift" "$SCRATCH/three.log"; then
    report 0 "the Zig comptime gate rejected it: $(grep -m1 -o 'ABI drift.*' "$SCRATCH/three.log" | cut -c1-80)"
elif [ "$three_rc" -ne 0 ]; then
    report 1 "build failed, but not on the ABI drift assert:
$(sed 's/^/        /' "$SCRATCH/three.log" | head -5)"
else
    report 1 "a kernel built against a wrong offset — the comptime gate is not checking"
fi
echo

# ── The real tree must be untouched ──────────────────────────────────────────
echo "4. the real tree must be byte-identical afterwards"
after="$(sha256sum include/evil_weevil/ee.h src/interface/generated/ee_layout.zig)"
if [ "$before" = "$after" ]; then
    report 0 "both committed artefacts are unchanged by the self-test"
else
    report 1 "the self-test modified the real tree (it must only touch scratch copies)"
fi

echo
if [ "$fail" -gt 0 ]; then
    echo "RESULT: FAIL ($fail gate(s) missed a deliberate breakage, $pass behaved correctly)"
    echo "        A gate that does not fail here is not protecting anything."
    exit 1
fi
echo "RESULT: PASS ($pass/$pass) — every layer rejected the breakage it is responsible for"
