# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
#
# THE ABI SEAM (Phase 1)
#
# Imported by ../../Justfile via `import? "build/just/seam.just"`.
#
# The seam is four artefacts that must agree, and these recipes are how you check
# that they do — rather than how you hope they do:
#
#   src/interface/Abi/Types.idr      the model: fields and sizes, in Idris2
#   src/interface/Abi/Layout.idr     the proofs: offsets and sizes, checked
#   include/evil_weevil/ee.h          the C ABI a host compiles against
#   src/interface/generated/ee_layout.zig   the same numbers, for the kernel
#
# The header and the Zig file are GENERATED and COMMITTED: committed so that a
# host needs no Idris2 toolchain to build against the ABI, generated so that
# nobody hand-edits a number. `just abi-check` is what keeps those two facts from
# contradicting each other — it regenerates and diffs, so a hand-edited header
# fails the build instead of shipping.
#
# Naming: `abi-gen` (write), `abi-check` (prove the committed copy is current),
# `kernel-*` (build and test the Zig side), `seam-check` (all of it, in order).

# ── The generator ────────────────────────────────────────────────────────────

# Build the ABI generator. Idris2 only links a PROGRAM here (the model and proofs
# elsewhere are checked with --check, which is why `just proof-check-idris2` does
# not need this step).
abi-gen-build:
    @echo "==> building the ABI generator (Idris2)"
    @idris2 --source-dir src/interface --build-dir _build/idris2 -o ee-abi-gen src/interface/Abi/Gen.idr
    @echo "    built _build/idris2/exec/ee-abi-gen"

# Regenerate the C header and the Zig layout from the Idris2 model.
# Writes: include/evil_weevil/ee.h, src/interface/generated/ee_layout.zig
abi-gen: abi-gen-build
    @echo "==> generating the seam from src/interface/Abi/Types.idr"
    @./_build/idris2/exec/ee-abi-gen .
    @echo "    (run 'just abi-check' to prove the committed copies match)"

# Prove the committed header and Zig layout are exactly what the model produces.
# This is the anti-drift gate: it regenerates into a scratch root and diffs. It
# FAILS if someone hand-edited either file, or if a change to the model was not
# regenerated into them — which is the only way a frozen ABI can quietly move.
abi-check: abi-gen-build
    @set -eu; \
    scratch=_build/abi-check; \
    rm -rf "$scratch"; \
    mkdir -p "$scratch/include/evil_weevil" "$scratch/src/interface/generated"; \
    ./_build/idris2/exec/ee-abi-gen "$scratch" > /dev/null; \
    ok=1; \
    for f in include/evil_weevil/ee.h src/interface/generated/ee_layout.zig; do \
      if ! diff -u "$f" "$scratch/$f" > _build/abi-drift.txt 2>&1; then \
        echo "FAIL: $f differs from the generated form:"; \
        head -40 _build/abi-drift.txt; \
        echo "      (run 'just abi-gen' and commit the result — do not hand-edit)"; \
        ok=0; \
      fi; \
    done; \
    rm -f _build/abi-drift.txt; \
    if [ "$ok" = 1 ]; then echo "PASS: the committed ABI matches the model"; else exit 1; fi

# ── The C side of the seam ───────────────────────────────────────────────────

# Compile the generated header on its own, so its _Static_asserts actually RUN.
# A header that has never been compiled is a header whose asserts have never
# fired: this is the cheapest check in the repository and the one that catches a
# generator emitting a size nobody ever laid out.
abi-header-check:
    @echo "==> compiling the generated header as C11 (its _Static_asserts run here)"
    @printf '#include <evil_weevil/ee.h>\nint main(void){return (int)(sizeof(ee_snapshot) + sizeof(ee_context));}\n' > _build/abi-header-check.c
    @gcc -std=c11 -Wall -Wextra -Werror -Iinclude -c _build/abi-header-check.c -o _build/abi-header-check.o
    @echo "    PASS: every _Static_assert in include/evil_weevil/ee.h holds"

# ── The Zig side of the seam ─────────────────────────────────────────────────

# Build the kernel as a static C library. The Zig comptime gate runs here: if the
# kernel's structs drift from the generated numbers, this FAILS TO COMPILE rather
# than corrupting a host's memory later.
kernel-build:
    @echo "==> building libevil_weevil.a (Zig kernel + C ABI)"
    @zig build --build-file src/interface/ffi/build.zig
    @ls -la src/interface/ffi/zig-out/lib/libevil_weevil.a

# Run the null-host harness (Zig) and the FFI boundary tests.
kernel-test:
    @echo "==> null host + FFI boundary tests"
    @zig build test --build-file src/interface/ffi/build.zig --summary all

# The same acceptance test from the other side: a C host that includes only the
# generated header and links only the static library. If this passes, the ABI is
# usable by a language that knows nothing about Zig or Idris2.
kernel-host-test: kernel-build
    @echo "==> building and running the C null host (tests/host/null_host.c)"
    @mkdir -p _build
    @gcc -std=c11 -Wall -Wextra -Werror -Iinclude tests/host/null_host.c \
        src/interface/ffi/zig-out/lib/libevil_weevil.a -o _build/null-host
    @./_build/null-host

# Prove the gates FAIL when the ABI is broken. Three deliberate breakages in
# scratch copies: a widened field (the generator must refuse), a hand-edited C
# offset define (the C compiler must reject it), a hand-edited Zig offset (the
# build must fail at comptime). A gate nobody has watched fail is not a gate —
# this is the recipe that makes that sentence checkable rather than rhetorical.
abi-gate-self-test:
    @echo "==> breaking the ABI three ways to prove the gates notice"
    @bash scripts/abi-gate-self-test.sh

# ── The whole seam, in order ─────────────────────────────────────────────────

# Phase 1 acceptance: model → proofs → generation → no drift → C header compiles
# → kernel builds and asserts its own layout → both hosts agree on 10,000 ticks.
seam-check: abi-check abi-header-check kernel-test kernel-host-test abi-gate-self-test
    @echo ""
    @echo "SEAM OK — the model, the header, the kernel and both null hosts agree,"
    @echo "          and every gate above has been watched to fail on a broken ABI."
