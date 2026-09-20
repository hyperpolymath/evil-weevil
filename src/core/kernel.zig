// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//
// The kernel: the host-agnostic intelligence, v0.
//
// This is the implementation of the rule specified and proved about in
// `src/interface/Abi/Foreign.idr` (`decide`, `tickModel`). Keep the two in step:
// the specification is the Idris2 module, this is the code that runs, and the
// golden trace in `tests/golden/` is the differential tie between them.
//
// Everything here is integer arithmetic. No floating point, no `libm`, no
// allocation, no clock, no I/O — the properties ADR-0006 requires are also the
// properties that make a replay bit-exact.
//
// The kernel is deliberately naive in its POLICY (a five-branch rule over health,
// ammo, contacts and range) and strict in its DISCIPLINE (deterministic,
// budgeted, capability-aware). Phase 2 grows the policy; nothing here should grow
// a dependency.

const abi = @import("abi");

// ── Fixed point, Q16.16 ─────────────────────────────────────────────────────
// Multiplication goes through a 64-bit intermediate and shifts back down, so the
// result is exact wherever the product is representable.

pub fn fxMul(a: i32, b: i32) i32 {
    const p: i64 = @as(i64, a) * @as(i64, b);
    return @intCast(p >> 16);
}

pub fn fxDiv(a: i32, b: i32) i32 {
    if (b == 0) return 0;
    const p: i64 = (@as(i64, a) << 16);
    return @intCast(@divTrunc(p, @as(i64, b)));
}

pub fn fxAbs(a: i32) i32 {
    return if (a < 0) -a else a;
}

/// Clamp to `[lo, hi]`. Total: every input has an answer, including hi < lo.
pub fn fxClamp(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// ── Deterministic RNG ───────────────────────────────────────────────────────
// SplitMix64. The point is not statistical excellence; it is that the same seed
// and the same call count give the same numbers on every platform, forever.

pub fn rngNext(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z: u64 = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// ── Perception: nearest contact ─────────────────────────────────────────────
// Contacts are published 0..contact_count-1 by the host. "Nearest" is the least
// distance; ties go to the LOWEST index, which keeps the choice deterministic
// rather than merely arbitrary.

pub const Nearest = struct {
    index: usize,
    id: u16,
    distance: i32,
    threat: i32,
    bearing_cos: u16,
    bearing_sin: u16,
};

/// Nearest contact, or null when the snapshot declares none. A contact_count
/// larger than the array is clamped rather than trusted: the host may be wrong,
/// and a wrong count must not read past the end of the struct.
pub fn nearestContact(snap: *const abi.EeSnapshot) ?Nearest {
    const declared = snap.contact_count;
    const available: usize = 8;
    const count: usize = if (declared > available) available else declared;
    if (count == 0) return null;

    const contacts = [8]abi.EeContact{
        snap.contact0, snap.contact1, snap.contact2, snap.contact3,
        snap.contact4, snap.contact5, snap.contact6, snap.contact7,
    };

    var best: usize = 0;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        if (contacts[i].distance < contacts[best].distance) best = i;
    }
    const c = contacts[best];
    return Nearest{
        .index = best,
        .id = c.id,
        .distance = c.distance,
        .threat = c.threat,
        .bearing_cos = c.bearing_cos,
        .bearing_sin = c.bearing_sin,
    };
}

// ── Decision ────────────────────────────────────────────────────────────────

pub const Decision = struct {
    action: u32,
    target: u32,
    priority: u32,
    speed: i32,
    move_x: i32,
    move_y: i32,
    look_x: i32,
    look_y: i32,
};

/// Branch conditions, in Q16.16. These ARE the policy: changing one changes what
/// enemies do, so they live in one place with the reason beside them.
const WOUNDED_BELOW: i32 = 16384; // 0.25 — "hurt enough to consider running"
const ATTACK_RANGE: i32 = 65536; // 1.00 — can engage from here
const FLEE_RANGE: i32 = 131072; // 2.00 — but only runs from threats this close

/// The v0 rule. The branch ORDER is the policy: an unarmed agent reloads even
/// while wounded and under fire, which `Abi.Foreign.reloadOutranksFlee` pins.
pub fn decide(snap: *const abi.EeSnapshot) Decision {
    const near = nearestContact(snap);

    // 1. No ammo: reload. Outranks everything, including self-preservation.
    if (snap.ammo == 0) {
        return .{
            .action = abi.ACTION_RELOAD,
            .target = 0,
            .priority = 65536, // 1.00
            .speed = 0,
            .move_x = 0,
            .move_y = 0,
            .look_x = 0,
            .look_y = 0,
        };
    }

    // 2. Nothing to fight: advance.
    if (near == null) {
        return .{
            .action = abi.ACTION_ADVANCE,
            .target = 0,
            .priority = 26214, // 0.40
            .speed = abi.FX_ONE,
            .move_x = 0,
            .move_y = 0,
            .look_x = 0,
            .look_y = 0,
        };
    }

    const n = near.?;
    const move_away: i32 = -@as(i32, n.bearing_cos);
    const move_away_y: i32 = -@as(i32, n.bearing_sin);

    // 3. Wounded and a threat within flee range: break off.
    if (snap.health < WOUNDED_BELOW and n.distance < FLEE_RANGE) {
        return .{
            .action = abi.ACTION_FLEE,
            .target = n.id,
            .priority = 58982, // 0.90
            .speed = 2 * abi.FX_ONE,
            .move_x = move_away,
            .move_y = move_away_y,
            .look_x = @intCast(n.bearing_cos),
            .look_y = @intCast(n.bearing_sin),
        };
    }

    // 4. In range: attack, holding position.
    if (n.distance <= ATTACK_RANGE) {
        return .{
            .action = abi.ACTION_ATTACK,
            .target = n.id,
            .priority = 52428, // 0.80
            .speed = 0,
            .move_x = move_away,
            .move_y = move_away_y,
            .look_x = @intCast(n.bearing_cos),
            .look_y = @intCast(n.bearing_sin),
        };
    }

    // 5. Otherwise close the distance.
    return .{
        .action = abi.ACTION_ADVANCE,
        .target = n.id,
        .priority = 26214, // 0.40
        .speed = abi.FX_ONE,
        .move_x = @intCast(n.bearing_cos),
        .move_y = @intCast(n.bearing_sin),
        .look_x = @intCast(n.bearing_cos),
        .look_y = @intCast(n.bearing_sin),
    };
}

// ── The tick ────────────────────────────────────────────────────────────────

/// Work the decision costs, in budget units. Crude on purpose at v0: five fixed
/// units plus one per contact examined, mirroring `tickModel` in Abi.Foreign.
pub fn workUnits(snap: *const abi.EeSnapshot) u32 {
    return 5 + @as(u32, snap.contact_count);
}

/// One tick, as a pure function of (context, snapshot, agent). No allocation, no
/// I/O, no host calls: the caller passes the state and receives the intent.
///
/// The budget guard degrades the agent's own behaviour rather than the frame:
/// when the work would exceed the host's allowance, the kernel still answers, but
/// says so in `flags` and reports the clamped usage, so a host can see which
/// agents are being starved and act.
pub fn tick(
    ctx: *abi.EeContext,
    snap: *const abi.EeSnapshot,
    agent: *abi.EeAgent,
) abi.EeIntent {
    const wanted = workUnits(snap);
    const budget = ctx.budget_units;
    const used: u32 = if (wanted > budget) budget else wanted;
    const degraded: bool = wanted > budget;

    // The RNG advances every tick whether or not this rule reads it, so the
    // stream is a function of the tick count alone and never depends on a branch
    // taken earlier. A Phase 2 policy that consumes randomness inherits a stream
    // that already has this property.
    _ = rngNext(&agent.rng_state);

    const d = decide(snap);

    var flags: u32 = 0;
    if (degraded) flags |= abi.INTENT_FLAG_DEGRADED;
    if (agent.cached_target != d.target) flags |= abi.INTENT_FLAG_NEW_TARGET;

    agent.tick_last = snap.tick;
    agent.cached_action = d.action;
    agent.cached_target = d.target;
    agent.budget_used = used;
    if (degraded) agent.degraded_ticks +%= 1;

    ctx.ticks_run +%= 1;
    if (degraded) ctx.degraded_ticks +%= 1;

    return .{
        .action = d.action,
        .target_id = d.target,
        .move_x = d.move_x,
        .move_y = d.move_y,
        .move_z = 0,
        .look_x = d.look_x,
        .look_y = d.look_y,
        .speed = d.speed,
        .priority = d.priority,
        .budget_used = used,
        .flags = flags,
        .reserved0 = 0,
    };
}

// ── Capability degradation ──────────────────────────────────────────────────
// ADR-0004: an absent capability narrows what the kernel will ask for, rather
// than aborting the host. v0 has one such rule, and one place to grow them.

/// Does the host declare this capability?
///
/// Takes a MASK (`abi.CAP_*`), not a bit index: the generated constants are masks
/// in both languages, which is what lets the same number appear in a C host and in
/// this file and mean the same thing.
pub fn hasCapability(ctx: *const abi.EeContext, mask: u32) bool {
    return (ctx.capabilities & mask) != 0;
}

/// Without navigation data the kernel may not ask an agent to leave its ground:
/// ADVANCE is downgraded to HOLD. This is the ladder in miniature — the same
/// shape later capabilities will use.
pub fn degradeForCapabilities(ctx: *const abi.EeContext, intent: *abi.EeIntent) void {
    if (!hasCapability(ctx, abi.CAP_NAVMESH) and intent.action == abi.ACTION_ADVANCE) {
        intent.action = abi.ACTION_HOLD;
        intent.speed = 0;
        intent.move_x = 0;
        intent.move_y = 0;
        intent.flags |= abi.INTENT_FLAG_UNREACHABLE;
    }
}
