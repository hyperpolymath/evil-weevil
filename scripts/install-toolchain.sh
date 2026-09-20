#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
#
# install-toolchain.sh — the three tools this repository cannot be checked without.
#
#   bash scripts/install-toolchain.sh [--check] [--prefix DIR]
#
#     --check    report what is present and missing; install nothing, exit 1 if
#                anything is missing. Use this in CI as a fast preflight, and on
#                a developer's machine to find out what `just seam-check` needs.
#     --prefix   where to install (default: ~/.cache/evil-weevil/toolchain).
#                CI passes a directory it caches; the default is a cache path
#                precisely so a local install is also a cache and never lands in
#                the repository.
#
# WHY A SCRIPT AND NOT A LIST OF APT PACKAGES
#
# Neither tool is available in a form that makes sense here:
#
#   * Idris2 publishes source only — no Linux binaries in any release, and no
#     conda/apt package. It must be bootstrapped with Chez Scheme. The v0.7.0
#     tarball ships PRE-GENERATED Scheme for the compiler itself, so the whole
#     bootstrap needs only Chez Scheme, make, gcc and GMP.
#   * Zig's own versions matter: this repository's build depends on 0.16.0
#     semantics. `zig = "latest"` in mise.toml was inherited from the template and
#     is exactly wrong for a project whose central claim is a frozen ABI — a new
#     Zig is free to change the build out from under the artefact.
#   * `just` is not a mise registry package either, and — measured against the
#     Ubuntu 24.04 GitHub runner image's own software list on 2026-09-20 — it is
#     not on ubuntu-latest. The seam gate is `just seam-check`, so a workflow that
#     assumes the runner has `just` fails at its first command; here it comes from
#     a pinned release, with the tarball's SHA-256 checked before extraction.
#
# Everything is pinned, idempotent and checked: running it twice is a no-op, and
# the versions are compared, not assumed. Numbers are the ones this repository was
# measured against (see DEVELOPMENT-PLAN.adoc and STATE.a2ml).
#
# Exit: 0 = both tools present at the pinned versions; 1 = missing and not
# installing (with --check), or an install step failed.

set -euo pipefail

ZIG_VERSION="0.16.0"
IDRIS2_VERSION="0.7.0"
JUST_VERSION="1.58.0"
# The digest of just-1.58.0-x86_64-unknown-linux-musl.tar.gz as published on
# 2026-08-03. It is committed here rather than fetched alongside the tarball: a
# checksum downloaded from the same place as the thing it checks proves only that
# the download was not corrupted on the way, which is worth something, but not
# what "verified" should mean. Bump both together, in one commit.
JUST_SHA256="4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${EE_TOOLCHAIN_PREFIX:-$HOME/.cache/evil-weevil/toolchain}"
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
        -h|--help) sed -n '4,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "usage: $(basename "$0") [--check] [--prefix DIR]" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# The installed version, or empty. Tolerant of tools that print to stderr.
zig_version() {
    have zig || return 0
    zig version 2>/dev/null | head -1
}
idris2_version() {
    have idris2 || return 0
    idris2 --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1
}
just_version() {
    have just || return 0
    just --version 2>/dev/null | sed -n 's/^just \([0-9][0-9.]*\).*/\1/p' | head -1
}

ZIG_HAVE="$(zig_version)"
IDRIS2_HAVE="$(idris2_version)"
JUST_HAVE="$(just_version)"

# ── Verify, rather than announce ─────────────────────────────────────────────
# A toolchain script's job is that the tools WORK, not that they exist. A compiler
# that starts and cannot find its own base library is a failure no version string
# reveals — and it is the failure a relocated install produces.
verify_idris2() {
    local probe
    probe="$(mktemp -d)"
    cat > "$probe/Probe.idr" <<'PROBE'
module Probe

import Data.Nat

%default total

theCompilersBaseLibraryIsReachable : LTE 3 5
theCompilersBaseLibraryIsReachable = LTESucc (LTESucc (LTESucc LTEZero))
PROBE
    if ( cd "$probe" && idris2 --check Probe.idr >/dev/null 2>&1 ); then
        rm -rf "$probe"
        return 0
    fi
    rm -rf "$probe"
    return 1
}

say "evil-weevil toolchain"
say "  zig     want $ZIG_VERSION  have ${ZIG_HAVE:-none}"
say "  idris2 want $IDRIS2_VERSION  have ${IDRIS2_HAVE:-none}"
say "  just    want $JUST_VERSION  have ${JUST_HAVE:-none}"

missing=0
[ "$ZIG_HAVE" = "$ZIG_VERSION" ] || missing=$((missing + 1))
[ "$IDRIS2_HAVE" = "$IDRIS2_VERSION" ] || missing=$((missing + 1))
[ "$JUST_HAVE" = "$JUST_VERSION" ] || missing=$((missing + 1))

if [ "$missing" -eq 0 ]; then
    if verify_idris2; then
        say ""
        say "PASS: all three tools present at the pinned versions, and idris2 compiles"
        say "      a module that imports Data.Nat."
        say "      (zig: $(command -v zig), idris2: $(command -v idris2), just: $(command -v just))"
        exit 0
    fi
    say ""
    say "FAIL: idris2 is at the right version but cannot find its base library."
    say "      Check IDRIS2_PREFIX, \$HOME/.idris2, or reinstall with this script."
    exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    say ""
    say "FAIL: $missing tool(s) missing or at the wrong version."
    say "      Run: bash scripts/install-toolchain.sh   (or --prefix DIR to choose where)"
    exit 1
fi

# ── just ─────────────────────────────────────────────────────────────────────
install_just() {
    say ""
    say "==> just $JUST_VERSION (the entry point to every gate)"
    local bin="$PREFIX/bin/just"
    local url="https://github.com/casey/just/releases/download/$JUST_VERSION/just-$JUST_VERSION-x86_64-unknown-linux-musl.tar.gz"
    if [ -x "$bin" ] && [ "$("$bin" --version 2>/dev/null | sed -n 's/^just \([0-9][0-9.]*\).*/\1/p')" = "$JUST_VERSION" ]; then
        say "    already installed at $bin"
        return 0
    fi
    mkdir -p "$PREFIX/bin"
    local tmp="$PREFIX/just-dl.tar.gz"
    say "    downloading $url"
    curl -fsSL -o "$tmp" "$url"
    if ! echo "$JUST_SHA256  $tmp" | sha256sum -c - >/dev/null 2>&1; then
        say "    FAIL: the tarball does not match the digest committed in this script."
        say "          Expected $JUST_SHA256"
        say "          Refusing to install it. If upstream really did re-release"
        say "          $JUST_VERSION, bump JUST_VERSION and JUST_SHA256 together."
        rm -f "$tmp"
        return 1
    fi
    # Only the binary is installed. The release also ships a man page and shell
    # completions; nothing here needs them, and a toolchain cache should hold what
    # the gates run, not a distribution directory.
    tar -xzf "$tmp" -C "$PREFIX/bin" just
    chmod +x "$bin"
    rm -f "$tmp"
    say "    installed $("$bin" --version) at $bin (sha256 verified)"
}

# ── Zig ──────────────────────────────────────────────────────────────────────
install_zig() {
    say ""
    say "==> zig $ZIG_VERSION"
    local dir="$PREFIX/zig-$ZIG_VERSION"
    local url="https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
    # The upstream tarball unpacks to a versioned directory of its own.
    if [ ! -x "$dir/zig" ]; then
        mkdir -p "$PREFIX"
        local tmp="$PREFIX/zig-dl.tar.xz"
        say "    downloading $url"
        curl -fsSL -o "$tmp" "$url"
        rm -rf "$dir" "$PREFIX/zig-x86_64-linux-$ZIG_VERSION"
        tar -xJf "$tmp" -C "$PREFIX"
        mv "$PREFIX/zig-x86_64-linux-$ZIG_VERSION" "$dir"
        rm -f "$tmp"
    fi
    mkdir -p "$PREFIX/bin"
    ln -sf "$dir/zig" "$PREFIX/bin/zig"
    say "    installed $("$dir/zig" version) at $dir/zig"
}

# ── Idris2 ───────────────────────────────────────────────────────────────────
install_idris2() {
    say ""
    say "==> idris2 $IDRIS2_VERSION (bootstrapped with Chez Scheme)"
    local dir="$PREFIX/idris2-$IDRIS2_VERSION"
    if [ ! -x "$dir/bin/idris2" ]; then
        if ! have chezscheme && ! have scheme && ! have chez; then
            say "    installing chezscheme (needs sudo)"
            sudo apt-get update -qq
            sudo apt-get install -y -qq chezscheme libgmp-dev build-essential
        fi
        local scheme
        scheme="$(command -v chezscheme || command -v scheme || command -v chez)"

        mkdir -p "$PREFIX/src"
        local src="$PREFIX/src/Idris2-$IDRIS2_VERSION"
        if [ ! -d "$src" ]; then
            say "    downloading Idris2 $IDRIS2_VERSION source"
            curl -fsSL -o "$PREFIX/src/idris2.tar.gz" \
                "https://github.com/idris-lang/Idris2/archive/refs/tags/v$IDRIS2_VERSION.tar.gz"
            tar -xzf "$PREFIX/src/idris2.tar.gz" -C "$PREFIX/src"
            rm -f "$PREFIX/src/idris2.tar.gz"
        fi

        say "    bootstrapping (this takes minutes; -j1 because stage 2 is memory-hungry)"
        ( cd "$src" && SCHEME="$scheme" make bootstrap -j1 )
        ( cd "$src" && make install PREFIX="$dir" )

        # Idris2 finds its support files and base libraries through IDRIS2_PREFIX,
        # defaulting to ~/.idris2 — deliberately NOT under the --prefix we pass to
        # make (measured: the libraries land in the default location even when an
        # install PREFIX is given). That default is left alone rather than fought:
        # it means a bare `idris2 --check foo.idr` works with no environment set,
        # which is what a contributor expects and what the justrecipes assume. CI
        # therefore caches ~/.idris2 as well as the prefix. Set IDRIS2_PREFIX
        # yourself to relocate it; this script does not move libraries it did not
        # put there.
    fi
    mkdir -p "$PREFIX/bin"
    ln -sf "$dir/bin/idris2" "$PREFIX/bin/idris2"
    say "    installed $("$PREFIX/bin/idris2" --version | head -1) at $dir/bin/idris2"
}

[ "$JUST_HAVE" = "$JUST_VERSION" ] || install_just
[ "$ZIG_HAVE" = "$ZIG_VERSION" ] || install_zig
[ "$IDRIS2_HAVE" = "$IDRIS2_VERSION" ] || install_idris2

# ── Verify, rather than announce ─────────────────────────────────────────────
# The point of a toolchain script is that the tools WORK, not that they exist. A
# compiler that starts and cannot find its own base library is the failure this
# catches, and it is exactly the failure that a version string does not reveal.
say ""
say ""
# The prefix is not on PATH yet — telling you to put it there is the next thing
# this script does — so the verification below MUST reach for the tools it just
# installed, not for whatever a shell happens to have. Without this line the
# check reported "just: command not found" while exiting 0, which is the worst
# shape a verification step can take.
export PATH="$PREFIX/bin:$PATH"
say "==> verifying the installed toolchain"
if verify_idris2; then
    say "    idris2: compiles a module that imports Data.Nat"
else
    say "    FAIL: idris2 cannot compile a module importing Data.Nat."
    say "          Its libraries are not where it looks for them."
    say "          Check IDRIS2_PREFIX (to relocate) or \$HOME/.idris2."
    exit 1
fi
say "    zig:    $(zig version) at $(command -v zig)"
say "    just:   $(just --version) at $(command -v just)"

say "==================================================================="
say "Add the toolchain to this shell:"
say "    export PATH=\"$PREFIX/bin:\$PATH\""
say ""
say "Then, from the repository root:"
say "    just proof-check-idris2     # the ABI model and proofs must compile"
say "    just seam-check             # model -> header -> kernel -> both null hosts"
say "==================================================================="
