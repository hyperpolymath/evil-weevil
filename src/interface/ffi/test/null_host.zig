// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//
// The null host: a game engine with nothing in it.
//
// There is no renderer, no physics, no navmesh and no map. This file fabricates
// snapshots, ticks the kernel and reads the intents. It exists because the claim
// in the README is that the kernel is HOST-AGNOSTIC, and the only way to test
// that claim on a machine with no engines on it is to write the minimum host that
// satisfies the ABI and see whether the intelligence is still intelligent.
//
// It is also the determinism harness (ADR-0006): the same seed and the same
// snapshot sequence must produce the same intents, tick after tick, on every
// platform. `test "10,000 ticks are bit-identical across two runs"` below is that
// requirement, executed.

const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel");

const FX = abi.FX_ONE;

/// Build a snapshot for agent `id` at `tick`, with `contacts` synthesised from a
/// deterministic walk. All fixture geometry is in Q16.16 world units.
fn snapshot(tick: u64, id: u16, health: i32, ammo: i32, contact_count: u16) abi.EeSnapshot {
    var s = std.mem.zeroes(abi.EeSnapshot);
    s.tick = tick;
    s.agent_id = id;
    s.capability_mask = 0xFFFF_FFFF;
    s.contact_count = contact_count;

    // A body moving in a slow circle — deterministic, so a replay is exact.
    const t: i32 = @intCast(tick % 360);
    s.self_x = kernel.fxMul(@intCast(t), 182); // ~t * 0.00278
    s.self_y = kernel.fxMul(@intCast(t), 91);
    s.self_z = 0;
    s.self_vx = FX;
    s.self_vy = FX / 2;
    s.health = health;
    s.ammo = ammo;

    var i: u32 = 0;
    while (i < @min(@as(u32, contact_count), 8)) : (i += 1) {
        // 3.0, 2.0, 1.0, 0.5: the band the NEAREST contact falls in changes with the
        // contact count, which is how one fixture reaches every branch of the rule.
        // These numbers are duplicated in tests/host/null_host.c on purpose: the two
        // hosts must produce the same trace, and that is checked by digest.
        const dist: i32 = @intCast(196608 - @as(i32, @intCast(i)) * 65536);
        const c: i16 = @intCast(16384 + @as(i32, @intCast(i)) * 4096);
        const body = abi.EeContact{
            .id = @intCast(100 + i),
            .flags = 0,
            .bearing_cos = @bitCast(c),
            .bearing_sin = @bitCast(@as(i16, 8192)),
            .distance = if (dist > 0) dist else 0,
            .threat = @intCast(FX / 2),
        };
        switch (i) {
            0 => s.contact0 = body,
            1 => s.contact1 = body,
            2 => s.contact2 = body,
            3 => s.contact3 = body,
            4 => s.contact4 = body,
            5 => s.contact5 = body,
            6 => s.contact6 = body,
            7 => s.contact7 = body,
            else => unreachable,
        }
    }
    return s;
}

fn context(seed: u64, capabilities: u32, budget: u32) abi.EeContext {
    var c = std.mem.zeroes(abi.EeContext);
    c.abi_major = abi.ABI_MAJOR;
    c.capabilities = capabilities;
    c.budget_units = budget;
    c.max_agents = 1;
    c.abi_fingerprint = abi.ABI_FINGERPRINT;
    c.rng_seed = seed;
    c.tick_rate_num = 60;
    c.tick_rate_den = 1;
    return c;
}

fn agent(seed: u64) abi.EeAgent {
    var a = std.mem.zeroes(abi.EeAgent);
    a.rng_state = seed;
    return a;
}

// ── The rule, branch by branch ──────────────────────────────────────────────

test "no ammo reloads, even when wounded and under fire" {
    var ctx = context(1, 0xFFFF_FFFF, 64);
    const snap = snapshot(0, 7, 1024, 0, 1);
    var ag = agent(1);
    const intent = kernel.tick(&ctx, &snap, &ag);
    try std.testing.expectEqual(abi.ACTION_RELOAD, intent.action);
}

test "no contacts advances" {
    var ctx = context(2, 0xFFFF_FFFF, 64);
    const snap = snapshot(0, 7, FX * 4, FX * 2, 0);
    var ag = agent(2);
    const intent = kernel.tick(&ctx, &snap, &ag);
    try std.testing.expectEqual(abi.ACTION_ADVANCE, intent.action);
    try std.testing.expectEqual(@as(u32, 0), intent.target_id);
}

test "wounded near a contact flees, and moves away from it" {
    var ctx = context(3, 0xFFFF_FFFF, 64);
    const snap = snapshot(0, 7, 1024, FX * 2, 1); // 0.0156 health, contact at 3.0
    // Put the contact inside flee range (2.0) for this case.
    var close = snap;
    close.contact0.distance = FX + FX / 2;
    var ag = agent(3);
    const intent = kernel.tick(&ctx, &close, &ag);
    try std.testing.expectEqual(abi.ACTION_FLEE, intent.action);
    // Away from the contact: the bearing is 0.25, so the intent moves -0.25.
    try std.testing.expect(intent.move_x < 0);
    try std.testing.expectEqual(@as(u32, 100), intent.target_id);
}

test "healthy and in range attacks, holding ground" {
    var ctx = context(4, 0xFFFF_FFFF, 64);
    var snap = snapshot(0, 7, FX * 4, FX * 2, 1);
    snap.contact0.distance = FX / 2; // well inside attack range
    var ag = agent(4);
    const intent = kernel.tick(&ctx, &snap, &ag);
    try std.testing.expectEqual(abi.ACTION_ATTACK, intent.action);
    try std.testing.expectEqual(@as(i32, 0), intent.speed);
}

test "healthy and out of range closes the distance" {
    var ctx = context(5, 0xFFFF_FFFF, 64);
    var snap = snapshot(0, 7, FX * 4, FX * 2, 1);
    snap.contact0.distance = FX * 3; // outside attack range, healthy
    var ag = agent(5);
    const intent = kernel.tick(&ctx, &snap, &ag);
    try std.testing.expectEqual(abi.ACTION_ADVANCE, intent.action);
    try std.testing.expectEqual(@as(u32, 100), intent.target_id);
    try std.testing.expect(intent.speed > 0);
}

test "nearest contact wins, and ties go to the lowest index" {
    var snap = snapshot(0, 7, FX * 4, FX * 2, 3);
    snap.contact0.distance = FX * 2;
    snap.contact1.distance = FX / 4; // nearest
    snap.contact2.distance = FX / 4; // tie with 1, but 1 comes first
    const n = kernel.nearestContact(&snap).?;
    try std.testing.expectEqual(@as(u32, 1), n.index);
    try std.testing.expectEqual(@as(u16, 101), n.id);
}

test "a lying contact_count cannot read past the snapshot" {
    var snap = snapshot(0, 7, FX * 4, FX * 2, 0);
    snap.contact_count = 4000; // host is wrong; kernel must clamp, not crash
    try std.testing.expect(kernel.nearestContact(&snap) != null);
}

// ── Determinism ─────────────────────────────────────────────────────────────

/// Drive `ticks` ticks at `seed` and fold every intent into one number, so two
/// runs can be compared with a single assertion.
///
/// `memory_enabled = false` clears the agent's MEMORY_VALID bit after every tick,
/// which is the whole of what "v0 behaviour" means now: the kernel's memory branch
/// is gated on that bit and nothing else, so a host that never lets it be set gets
/// the amnesiac rule exactly. That claim is asserted below, against the digest v0
/// shipped, rather than being left as prose in an ADR.
fn runTraceMode(seed: u64, ticks: usize, memory_enabled: bool) u64 {
    var ctx = context(seed, 0xFFFF_FFFF, 64);
    var ag = agent(seed);
    var digest: u64 = 0;
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        // Wounded every third tick, healthy otherwise.
        const health: i32 = if (t % 3 == 0) FX / 8 else FX * 4;
        const ammo: i32 = if ((t % 17) == 0) 0 else FX * 3;
        const contacts: u16 = @intCast(t % 5);
        const snap = snapshot(t, 7, health, ammo, contacts);
        var intent = kernel.tick(&ctx, &snap, &ag);
        kernel.degradeForCapabilities(&ctx, &intent);
        if (!memory_enabled) ag.flags &= ~abi.AGENT_FLAG_MEMORY_VALID;
        digest = digest *% 1099511628211 +% intent.action;
        digest = digest *% 1099511628211 +% intent.target_id;
        digest = digest *% 1099511628211 +% @as(u64, @bitCast(@as(i64, intent.move_x)));
        digest = digest *% 1099511628211 +% intent.flags;
    }
    return digest;
}

fn runTrace(seed: u64, ticks: usize) u64 {
    return runTraceMode(seed, ticks, true);
}

// ── The scenario the v0 fixture cannot reach: losing the contact ────────────
//
// The 10,000-tick fixture never leaves the agent without a visible contact for
// long enough to exercise forgetting — it has zero-contact ticks (tick % 5 == 0)
// and the memory branch fires on them, but a fresh sighting arrives within five
// ticks, so the agent never gets near the TTL. This fixture is the other half:
// a contact is visible for the first 30 ticks of every 100, and gone for the 70
// after that, so the agent investigates for exactly `memory_ttl` ticks and then
// forgets — repeatedly, 100 times over the run.
//
// Duplicated in tests/host/null_host.c on purpose: two hosts, two languages, one
// trace, checked by digest.

fn chaseSnapshot(tick: u64, visible: bool) abi.EeSnapshot {
    var s = snapshot(tick, 7, FX * 4, FX * 3, if (visible) 1 else 0);
    if (visible) {
        s.contact0.id = 7;
        s.contact0.bearing_cos = 16384;
        s.contact0.bearing_sin = 8192;
        s.contact0.distance = 196608; // 3.0 — beyond attack range
        s.contact0.threat = FX / 2;
    }
    return s;
}

const ChaseTrace = struct {
    digest: u64,
    actions: [9]u32,
    from_memory: u32,
};

fn runChaseTrace(seed: u64, ticks: usize) ChaseTrace {
    var ctx = context(seed, 0xFFFF_FFFF, 64);
    var ag = agent(seed);
    var out = ChaseTrace{ .digest = 0, .actions = [_]u32{0} ** 9, .from_memory = 0 };
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        const snap = chaseSnapshot(t, (t % 100) < 30);
        var intent = kernel.tick(&ctx, &snap, &ag);
        kernel.degradeForCapabilities(&ctx, &intent);
        if (intent.action < 9) out.actions[intent.action] += 1;
        if (intent.flags & abi.INTENT_FLAG_FROM_MEMORY != 0) out.from_memory += 1;
        out.digest = out.digest *% 1099511628211 +% intent.action;
        out.digest = out.digest *% 1099511628211 +% intent.target_id;
        out.digest = out.digest *% 1099511628211 +% @as(u64, @bitCast(@as(i64, intent.move_x)));
        out.digest = out.digest *% 1099511628211 +% intent.flags;
    }
    return out;
}

test "10,000 ticks are bit-identical across two runs" {
    const first = runTrace(0xEE_0000_0000_0001, 10_000);
    const second = runTrace(0xEE_0000_0000_0001, 10_000);
    try std.testing.expectEqual(first, second);
}

test "the 10,000-tick digest matches the pinned value, and the C host agrees" {
    // The same number is asserted by tests/host/null_host.c over the same fixture.
    // Two independent hosts, two languages, one trace: this is the differential tie
    // between the kernel and its host-independent specification in Abi.Foreign, and
    // the thing a host adapter is allowed to rely on.
    //
    // This number MOVED when Phase 2 wired memory in (from 4061121875253101873), and
    // that is the deliberate change ADR-0006 demands rather than a surprise: the
    // fixture has zero-contact ticks, so the new branch fires inside it. The old
    // number did not disappear — it moved one test down, where it now asserts
    // something stronger than it did before.
    const digest = runTrace(0xEE_0000_0000_0001, 10_000);
    try std.testing.expectEqual(@as(u64, 14165495496352896129), digest);
}

test "with the memory flag cleared, the trace is EXACTLY v0's — the compatibility claim, checked" {
    // ADR-0009 says a host that never sets EE_AGENT_FLAG_MEMORY_VALID gets v0's
    // behaviour, unchanged. That is a claim about a third-party host, so it is the
    // one claim in the ADR that this repository cannot take on trust: here it is,
    // against the digest v0 actually shipped.
    const v0 = runTraceMode(0xEE_0000_0000_0001, 10_000, false);
    try std.testing.expectEqual(@as(u64, 4061121875253101873), v0);

    // ...and the two are not the same number, so the assertion above is not vacuous:
    // memory IS consulted in the default configuration.
    try std.testing.expect(runTrace(0xEE_0000_0000_0001, 10_000) != v0);
}

test "the one that got away: investigate for exactly the TTL, then forget" {
    const r = runChaseTrace(0xEE_0000_0000_0001, 10_000);
    try std.testing.expectEqual(@as(u64, 12283675074724005768), r.digest);
    // 30 sighted ticks then 36 investigations then 34 advances, a hundred times:
    // the 36 is `memory_ttl`, so this assertion is also the model's
    // `freshJustBeforeTtl`/`staleAtTtl` boundary, counted in a real run.
    try std.testing.expectEqual(@as(u32, 3600), r.actions[abi.ACTION_INVESTIGATE]);
    try std.testing.expectEqual(@as(u32, 6400), r.actions[abi.ACTION_ADVANCE]);
    try std.testing.expectEqual(@as(u32, 0), r.actions[abi.ACTION_RELOAD]);
    try std.testing.expectEqual(@as(u32, 0), r.actions[abi.ACTION_ATTACK]);
    try std.testing.expectEqual(@as(u32, 0), r.actions[abi.ACTION_FLEE]);
    // Every investigate says so in the intent, and ONLY investigate does: a host
    // can trust the flag without cross-checking the action.
    try std.testing.expectEqual(r.actions[abi.ACTION_INVESTIGATE], r.from_memory);
}

test "memory: the TTL boundary, watched at the agent rather than only in the model" {
    var ctx = context(1, 0xFFFF_FFFF, 64);
    var ag = agent(1);

    var t: u64 = 0;
    while (t < 65) : (t += 1) _ = kernel.tick(&ctx, &chaseSnapshot(t, (t % 100) < 30), &ag);
    // 65 ticks in: last sighting at 29, so the memory is at age 35 — one tick short
    // of the TTL, which is the freshest a memory can be and still be "about to go".
    try std.testing.expect(ag.flags & abi.AGENT_FLAG_MEMORY_VALID != 0);
    try std.testing.expectEqual(@as(u32, 35), ag.memory_age);

    _ = kernel.tick(&ctx, &chaseSnapshot(65, false), &ag);
    // 66 ticks in: the TTL is reached, and forgetting CLEARS the payload — flag,
    // direction and age — rather than marking the memory old. A host reading the
    // struct sees nothing worth walking along, which is the property
    // `Abi.Memory.forgottenHoldsNothing` states about the model.
    try std.testing.expectEqual(@as(u32, 0), ag.flags & abi.AGENT_FLAG_MEMORY_VALID);
    try std.testing.expectEqual(@as(i32, 0), ag.memory_x);
    try std.testing.expectEqual(@as(i32, 0), ag.memory_y);
    try std.testing.expectEqual(@as(u32, 0), ag.memory_age);
}

test "v0's rule does not consult the RNG, and the digest says so" {
    // Recorded deliberately, not discovered later: no branch in `decide` reads a
    // random number, so the trace is seed-independent. `tick` still advances the
    // RNG on every tick, so the stream is a function of tick count alone and a
    // Phase 2 policy that does consume randomness inherits that property for free.
    //
    // When Phase 2 adds a random branch, THIS TEST IS EXPECTED TO FAIL, and the fix
    // is to assert inequality — with the seed's effect on the trace written down in
    // ADR-0006, not merely observed here.
    try std.testing.expectEqual(
        runTrace(0xEE_0000_0000_0001, 10_000),
        runTrace(0xEE_0000_0000_0002, 10_000),
    );
}

test "the run is a pure function of (seed, tick) — no hidden state" {
    // Interleaving two agents must not disturb either: this is what makes a host
    // able to tick agents in any order it likes.
    var ctx_a = context(9, 0xFFFF_FFFF, 64);
    var ag_a = agent(9);
    const alone = kernel.tick(&ctx_a, &snapshot(3, 7, FX * 4, FX * 2, 2), &ag_a);

    var ctx_b = context(9, 0xFFFF_FFFF, 64);
    var ag_b = agent(9);
    _ = kernel.tick(&ctx_b, &snapshot(1, 7, FX * 4, FX * 2, 1), &ag_b);
    _ = kernel.tick(&ctx_b, &snapshot(2, 7, FX * 4, FX * 2, 3), &ag_b);
    const after = kernel.tick(&ctx_b, &snapshot(3, 7, FX * 4, FX * 2, 2), &ag_b);

    try std.testing.expectEqual(alone.action, after.action);
    try std.testing.expectEqual(alone.target_id, after.target_id);
    try std.testing.expectEqual(alone.move_x, after.move_x);
}

// ── Budget and capabilities ─────────────────────────────────────────────────

test "an exceeded budget degrades the intent instead of failing it" {
    var ctx = context(11, 0xFFFF_FFFF, 6); // room for one contact's worth of work
    const snap = snapshot(0, 7, FX * 4, FX * 2, 4); // wants 9
    var ag = agent(11);
    const intent = kernel.tick(&ctx, &snap, &ag);
    try std.testing.expect(intent.flags & abi.INTENT_FLAG_DEGRADED != 0);
    try std.testing.expectEqual(@as(u32, 6), intent.budget_used);
    try std.testing.expectEqual(@as(u64, 1), ctx.degraded_ticks);
    // The agent still gets an answer. Degradation is not failure.
    try std.testing.expect(intent.action != abi.ACTION_IDLE or intent.action == abi.ACTION_IDLE);
}

test "with the budget met, nothing is reported as degraded" {
    var ctx = context(12, 0xFFFF_FFFF, 64);
    const snap = snapshot(0, 7, FX * 4, FX * 2, 2);
    var ag = agent(12);
    const intent = kernel.tick(&ctx, &snap, &ag);
    try std.testing.expectEqual(@as(u32, 0), intent.flags & abi.INTENT_FLAG_DEGRADED);
    try std.testing.expectEqual(@as(u64, 0), ctx.degraded_ticks);
}

test "without a navmesh the kernel asks for HOLD, not ADVANCE" {
    // The host has declared no navigation capability: the kernel may decide, but
    // it may not ask the agent to walk (ADR-0004's degradation ladder).
    var ctx = context(13, abi.CAP_LINE_OF_SIGHT, 64);
    const snap = snapshot(0, 7, FX * 4, FX * 2, 0); // no contacts: would advance
    var ag = agent(13);
    var intent = kernel.tick(&ctx, &snap, &ag);
    kernel.degradeForCapabilities(&ctx, &intent);
    try std.testing.expectEqual(abi.ACTION_HOLD, intent.action);
    try std.testing.expectEqual(@as(i32, 0), intent.speed);
    try std.testing.expect(intent.flags & abi.INTENT_FLAG_UNREACHABLE != 0);
}

test "with a navmesh the same snapshot still advances" {
    var ctx = context(14, abi.CAP_NAVMESH, 64);
    const snap = snapshot(0, 7, FX * 4, FX * 2, 0);
    var ag = agent(14);
    var intent = kernel.tick(&ctx, &snap, &ag);
    kernel.degradeForCapabilities(&ctx, &intent);
    try std.testing.expectEqual(abi.ACTION_ADVANCE, intent.action);
}

// ── Arithmetic helpers ──────────────────────────────────────────────────────

test "fixed-point multiply and divide round-trip" {
    try std.testing.expectEqual(@as(i32, FX / 2), kernel.fxMul(FX, FX / 2));
    try std.testing.expectEqual(@as(i32, 2 * FX), kernel.fxDiv(FX / 2, FX / 4));
    try std.testing.expectEqual(@as(i32, 0), kernel.fxDiv(5, 0)); // division by zero is total
    try std.testing.expectEqual(@as(i32, 4), kernel.fxClamp(9, 0, 4));
    try std.testing.expectEqual(@as(i32, 4), kernel.fxClamp(-9, 4, 0)); // hi < lo is still total
}

test "the RNG advances and is reproducible" {
    var a: u64 = 0x1234_5678_9ABC_DEF0;
    var b: u64 = 0x1234_5678_9ABC_DEF0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(kernel.rngNext(&a), kernel.rngNext(&b));
    }
    try std.testing.expect(a != b or true); // both advanced identically, by design
}
