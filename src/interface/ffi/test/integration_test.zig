// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//
// The FFI boundary, as a host calls it.
//
// `null_host.zig` tests the kernel's behaviour with a host that does nothing.
// This file tests the SEAM: the exported symbols, their argument validation, and
// the refusals. The refusals are the point — a host that links against a moving
// ABI must be told so in a status code, because the alternative is a host that
// links successfully and corrupts memory later (ADR-0005).
//
// These call the real exported functions (`ee` is the FFI module), not copies of
// their logic, so a changed signature or a removed export fails here first.

const std = @import("std");
const ee = @import("ee");
const abi = @import("abi");

fn zeroDesc() abi.EeInitDesc {
    var d = std.mem.zeroes(abi.EeInitDesc);
    d.struct_size = @sizeOf(abi.EeInitDesc);
    d.abi_major = abi.ABI_MAJOR;
    d.abi_minor = abi.ABI_MINOR;
    d.capabilities = abi.CAP_LINE_OF_SIGHT;
    d.max_agents = 8;
    d.host_tick_num = 60;
    d.host_tick_den = 1;
    d.rng_seed = 0x1234_5678;
    d.abi_fingerprint = abi.ABI_FINGERPRINT;
    return d;
}

fn zeroCtx() abi.EeContext {
    return std.mem.zeroes(abi.EeContext);
}

fn zeroSnapshot() abi.EeSnapshot {
    var s = std.mem.zeroes(abi.EeSnapshot);
    s.contact_count = 1;
    s.health = abi.FX_ONE * 4;
    s.ammo = abi.FX_ONE * 2;
    s.contact0 = .{
        .id = 42,
        .flags = 0,
        .bearing_cos = 16384,
        .bearing_sin = 0,
        .distance = abi.FX_ONE / 2,
        .threat = abi.FX_ONE,
    };
    return s;
}

fn zeroAgent() abi.EeAgent {
    return std.mem.zeroes(abi.EeAgent);
}

// ── Introspection ───────────────────────────────────────────────────────────

test "version_info reports the ABI the header declares" {
    const v = ee.ee_version_info();
    try std.testing.expectEqual(@as(u16, @intCast(abi.ABI_MAJOR)), v.major);
    try std.testing.expectEqual(@as(u16, @intCast(abi.ABI_MINOR)), v.minor);
}

test "the fingerprint is exported and stable" {
    try std.testing.expectEqual(abi.ABI_FINGERPRINT, ee.ee_abi_fingerprint());
    try std.testing.expect(ee.ee_abi_fingerprint() != 0);
}

test "every status code has a name, and an unknown one does not crash" {
    const statuses = [_]u32{
        abi.STATUS_OK,                    abi.STATUS_BAD_PARAM,
        abi.STATUS_VERSION_MISMATCH,      abi.STATUS_FINGERPRINT_MISMATCH,
        abi.STATUS_CAPABILITY_UNSUPPORTED, abi.STATUS_BUFFER_TOO_SMALL,
        abi.STATUS_PANIC_CAUGHT,
    };
    for (statuses) |s| {
        const name = std.mem.span(ee.ee_status_name(s));
        try std.testing.expect(name.len > 0);
        try std.testing.expect(!std.mem.eql(u8, name, "ee_unknown_status"));
    }
    try std.testing.expectEqualStrings("ee_unknown_status", std.mem.span(ee.ee_status_name(9999)));
}

// ── Init: the happy path and every refusal ──────────────────────────────────

test "a well-formed descriptor initialises the context" {
    const desc = zeroDesc();
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_OK, ee.ee_init(&desc, &ctx));
    try std.testing.expectEqual(abi.ABI_FINGERPRINT, ctx.abi_fingerprint);
    try std.testing.expectEqual(@as(u64, 0), ctx.ticks_run);
    try std.testing.expectEqual(@as(u32, 8), ctx.max_agents);
}

test "null arguments are refused, not dereferenced" {
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_BAD_PARAM, ee.ee_init(null, &ctx));
    const desc = zeroDesc();
    try std.testing.expectEqual(abi.STATUS_BAD_PARAM, ee.ee_init(&desc, null));
}

test "a host compiled against a different struct size is refused" {
    var desc = zeroDesc();
    desc.struct_size = @sizeOf(abi.EeInitDesc) - 8;
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_BUFFER_TOO_SMALL, ee.ee_init(&desc, &ctx));
}

test "a host on a different major version is refused" {
    var desc = zeroDesc();
    desc.abi_major = abi.ABI_MAJOR + 1;
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_VERSION_MISMATCH, ee.ee_init(&desc, &ctx));
}

test "a host with a stale layout is refused, and one that declines the check is not" {
    var desc = zeroDesc();
    desc.abi_fingerprint = abi.ABI_FINGERPRINT + 1;
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_FINGERPRINT_MISMATCH, ee.ee_init(&desc, &ctx));

    // Zero means "I have not got a fingerprint": allowed, so an old minimal host
    // still works, while a host that states one is held to it.
    desc.abi_fingerprint = 0;
    try std.testing.expectEqual(abi.STATUS_OK, ee.ee_init(&desc, &ctx));
}

// ── Tick ────────────────────────────────────────────────────────────────────

test "a tick returns an intent and updates the context counters" {
    const desc = zeroDesc();
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_OK, ee.ee_init(&desc, &ctx));

    const snap = zeroSnapshot();
    var agent = zeroAgent();
    var intent = std.mem.zeroes(abi.EeIntent);

    try std.testing.expectEqual(abi.STATUS_OK, ee.ee_tick(&ctx, &snap, &agent, &intent));
    try std.testing.expectEqual(abi.ACTION_ATTACK, intent.action);
    try std.testing.expectEqual(@as(u32, 42), intent.target_id);
    try std.testing.expectEqual(@as(u64, 1), ctx.ticks_run);
}

test "tick refuses bad arguments and an uninitialised context" {
    var ctx = zeroCtx();
    const snap = zeroSnapshot();
    var agent = zeroAgent();
    var intent = std.mem.zeroes(abi.EeIntent);

    try std.testing.expectEqual(abi.STATUS_BAD_PARAM, ee.ee_tick(null, &snap, &agent, &intent));
    try std.testing.expectEqual(abi.STATUS_BAD_PARAM, ee.ee_tick(&ctx, null, &agent, &intent));
    try std.testing.expectEqual(abi.STATUS_BAD_PARAM, ee.ee_tick(&ctx, &snap, null, &intent));
    try std.testing.expectEqual(abi.STATUS_BAD_PARAM, ee.ee_tick(&ctx, &snap, &agent, null));

    // ctx was never initialised: abi_major is 0, so the call is refused rather
    // than answered with plausible garbage.
    try std.testing.expectEqual(abi.STATUS_VERSION_MISMATCH, ee.ee_tick(&ctx, &snap, &agent, &intent));
}

test "shutdown is safe on a null pointer and clears the run counters" {
    ee.ee_shutdown(null);
    const desc = zeroDesc();
    var ctx = zeroCtx();
    try std.testing.expectEqual(abi.STATUS_OK, ee.ee_init(&desc, &ctx));
    ee.ee_shutdown(&ctx);
    try std.testing.expectEqual(@as(u64, 0), ctx.ticks_run);
}
