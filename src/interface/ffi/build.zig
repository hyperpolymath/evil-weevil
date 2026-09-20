// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//
// Build for the Evil Weevil kernel and its C ABI.
//
//   zig build              — build libevil_weevil.a (the kernel as a C library)
//   zig build test         — run the null-host harness and the FFI boundary tests
//   zig build abi-check    — assert the ABI constants against the generated model
//
// Run through `just kernel-build` / `just kernel-test` so the Idris2 model is
// regenerated first: the Zig sources import the GENERATED `ee_layout.zig`, and a
// stale generation is the one way this build could pass while lying.
//
// Modules are declared explicitly rather than imported by relative path because
// Zig confines `@import` to a module's root directory: the kernel, the ABI
// bindings and the generated layout live in three different trees, so each is a
// module and each is imported by name.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // The generated layout: emitted by `Abi.Gen` from the Idris2 model.
    const layout = b.createModule(.{
        .root_source_file = b.path("../generated/ee_layout.zig"),
        .pic = true,
    });

    // The ABI as Zig sees it, with the comptime layout gate.
    const abi = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .pic = true,
        .target = target,
        .optimize = optimize,
    });
    abi.addImport("layout", layout);

    // The kernel: pure, integer-only, no host calls.
    const kernel = b.createModule(.{
        .root_source_file = b.path("../../core/kernel.zig"),
        .pic = true,
        .target = target,
        .optimize = optimize,
    });
    kernel.addImport("abi", abi);

    // The exported C ABI.
    const ffi = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .pic = true,
        .target = target,
        .optimize = optimize,
    });
    ffi.addImport("abi", abi);
    ffi.addImport("kernel", kernel);

    const lib = b.addLibrary(.{
        .name = "evil_weevil",
        .linkage = .static,
        .root_module = ffi,
    });
    b.installArtifact(lib);

    // ── Tests ───────────────────────────────────────────────────────────────
    // The null-host harness: a host with no engine behind it, which is the only
    // way to prove the kernel is host-agnostic rather than merely host-tolerant.
    const null_host = b.createModule(.{
        .root_source_file = b.path("test/null_host.zig"),
        .pic = true,
        .target = target,
        .optimize = optimize,
    });
    null_host.addImport("abi", abi);
    null_host.addImport("kernel", kernel);

    const null_host_tests = b.addTest(.{ .root_module = null_host });
    const run_null_host = b.addRunArtifact(null_host_tests);
    run_null_host.step.dependOn(b.getInstallStep());

    // The FFI boundary: the exported symbols, called the way a C host calls them.
    const boundary = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .pic = true,
        .target = target,
        .optimize = optimize,
    });
    boundary.addImport("ee", ffi);
    boundary.addImport("abi", abi);

    const boundary_tests = b.addTest(.{ .root_module = boundary });

    const test_step = b.step("test", "Run the null-host harness and the FFI boundary tests");
    test_step.dependOn(&run_null_host.step);
    test_step.dependOn(&b.addRunArtifact(boundary_tests).step);
}
