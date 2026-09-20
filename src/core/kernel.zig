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
// The kernel is deliberately naive in its POLICY and strict in its DISCIPLINE
// (deterministic, budgeted, capability-aware). Phase 2 has added perception memory
// (ADR-0009, `src/interface/Abi/Memory.idr`) and replaced the branch chain with a
// utility graph (ADR-0010, `src/interface/Abi/Utility.idr`) — a refactor that
// moved no digest. Nothing here has grown a dependency.

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
// ── The utility graph (Phase 2, ADR-0010) ──────────────────────────────────
// The five-branch chain IS the policy; these numbers are that policy with the
// branch structure taken out, so it can be extended by adding a score instead of
// by arguing about where a new branch goes. The model, and the proofs that each
// branch of v0 still comes out of the graph, are in src/interface/Abi/Utility.idr.
//
// Every weight here is a number the intents ALREADY reported in `priority`
// (65536/58982/52428/26214, plus Phase 2's 32768 for INVESTIGATE). That is why
// replacing the chain with a maximum over them moves no digest: it is the rule v0
// was already following, written where it can be read. If a future tuning changes
// a number, the digests move and that is the point.
//
// The weights are deliberately NOT in ee.h: policy weights are not ABI. A host may
// read `priority` to compare two intents, but a host that hard-codes 58982 as
// "flee" would break the day the graph is tuned, and tuning it is what the graph
// is for.

const UTILITY_RELOAD: u32 = 65536; // 1.00
const UTILITY_FLEE: u32 = 58982; // 0.90
const UTILITY_ATTACK: u32 = 52428; // 0.80
const UTILITY_INVESTIGATE: u32 = 32768; // 0.50
const UTILITY_ADVANCE: u32 = 26214; // 0.40

/// The candidates, in tie-break order — the model's `allCandidates`. The order is
/// v0's branch order, because a tie the scores cannot settle should be settled the
/// way the chain settled it, and the order is checked against the model, which
/// breaks ties the same way. `candidatesFor` below narrows this list for the one
/// moment where v0's memory branch outranked everything else.
const CANDIDATES = [_]u32{
    abi.ACTION_RELOAD,
    abi.ACTION_FLEE,
    abi.ACTION_ATTACK,
    abi.ACTION_INVESTIGATE,
    abi.ACTION_ADVANCE,
    abi.ACTION_HOLD,
};

/// One action's score in one moment. Thresholds are the same literals the model
/// pins (`Abi.Foreign`: 16384 wounded, 65536 attack range, 131072 flee range).
fn utilityOf(action: u32, snap: *const abi.EeSnapshot, near: ?Nearest, memory_fresh: bool) u32 {
    return switch (action) {
        abi.ACTION_RELOAD => if (snap.ammo == 0) UTILITY_RELOAD else 0,
        abi.ACTION_FLEE => if (near) |n|
            (if (snap.health < WOUNDED_BELOW and n.distance < FLEE_RANGE) UTILITY_FLEE else 0)
        else
            0,
        abi.ACTION_ATTACK => if (near) |n|
            (if (n.distance <= ATTACK_RANGE) UTILITY_ATTACK else 0)
        else
            0,
        // Not enough to have no contact: with nothing visible and nothing
        // remembered, walking is worth more than investigating nothing.
        abi.ACTION_INVESTIGATE => if (near == null and memory_fresh) UTILITY_INVESTIGATE else 0,
        abi.ACTION_ADVANCE => if (near != null)
            UTILITY_ADVANCE
        else if (memory_fresh)
            0 // the memory is worth more than a walk, so walking scores nothing
        else
            UTILITY_ADVANCE,
        // IDLE, TAKE_COVER, REGROUP and anything the ABI grows later: not
        // candidates. Zero can never beat a positive score, so this is a
        // deliberate "no opinion" rather than a silent default.
        else => 0,
    };
}

/// The first maximum, in candidate order.
/// The candidates for a MOMENT — the model's `Abi.Utility.candidates`, which is a
/// function of the situation rather than a constant list, and for one reason.
///
/// v0 decided with a chain and then ran its memory branch on the way out, so a
/// memory that was fresh and had nothing to compete with REPLACED the decision.
/// The chain and the memory branch disagree at exactly one kind of moment — nothing
/// visible, a fresh lead, no ammo: the chain says reload, the memory branch says
/// investigate — and the memory branch won, because it ran last.
///
/// Measured, not assumed: this trace drops contacts every fifth tick and empties
/// the magazine every seventeenth, so the collision lands on ticks 85, 170, ...
/// and letting reload win there moved the pinned digest from
/// 14165495496352896129 to 57428431722396483. So the moment is written as having
/// one candidate. Investigation is not scoring higher than reload — with nothing to
/// look at, the lead is the task, and raising its score instead would change the
/// priority the intent REPORTS, which is ABI.
///
/// Whether an ammo-less agent should investigate at all is a policy question this
/// refactor is not allowed to answer. It is recorded as open in ADR-0010; answering
/// it moves the digest, which is how the change announces itself as policy.
fn candidatesFor(near: ?Nearest, memory_fresh: bool) []const u32 {
    if (near == null and memory_fresh) return &[_]u32{abi.ACTION_INVESTIGATE};
    return &CANDIDATES;
}

fn chooseAction(snap: *const abi.EeSnapshot, near: ?Nearest, memory_fresh: bool) u32 {
    var best_action: u32 = abi.ACTION_HOLD;
    var best_score: u32 = 0;
    for (candidatesFor(near, memory_fresh)) |a| {
        const sc = utilityOf(a, snap, near, memory_fresh);
        if (sc > best_score) {
            best_score = sc;
            best_action = a;
        }
    }
    return best_action;
}

/// Decide what this agent should do.
///
/// Reads `agent` for exactly one thing — whether the memory is fresh — and reads
/// it BEFORE the tick's bookkeeping, so the freshness it acts on is the freshness
/// the tick opened with. That is what makes this the same rule as
/// `Abi.Memory.decideWithMemory` rather than a similar one.
pub fn decide(snap: *const abi.EeSnapshot, agent: *const abi.EeAgent) Decision {
    const near = nearestContact(snap);

    switch (chooseAction(snap, near, memoryFresh(agent))) {
        abi.ACTION_RELOAD => return .{
            .action = abi.ACTION_RELOAD,
            .target = 0,
            .priority = UTILITY_RELOAD,
            .speed = 0,
            .move_x = 0,
            .move_y = 0,
            .look_x = 0,
            .look_y = 0,
        },

        // FLEE and ATTACK score zero without a contact, so the graph cannot pick
        // them here without one. The `.?` is that invariant, asserted by the
        // switch rather than assumed by the reader.
        abi.ACTION_FLEE => {
            const n = near.?;
            return .{
                .action = abi.ACTION_FLEE,
                .target = n.id,
                .priority = UTILITY_FLEE,
                .speed = 2 * abi.FX_ONE,
                .move_x = -@as(i32, n.bearing_cos),
                .move_y = -@as(i32, n.bearing_sin),
                .look_x = @intCast(n.bearing_cos),
                .look_y = @intCast(n.bearing_sin),
            };
        },

        abi.ACTION_ATTACK => {
            const n = near.?;
            return .{
                .action = abi.ACTION_ATTACK,
                .target = n.id,
                .priority = UTILITY_ATTACK,
                .speed = 0,
                .move_x = -@as(i32, n.bearing_cos),
                .move_y = -@as(i32, n.bearing_sin),
                .look_x = @intCast(n.bearing_cos),
                .look_y = @intCast(n.bearing_sin),
            };
        },

        // The Phase 2 branch, unchanged in what it does and now reached by score
        // rather than by an `else if` in the tick.
        abi.ACTION_INVESTIGATE => return investigate(agent),

        abi.ACTION_ADVANCE => {
            if (near) |n| {
                return .{
                    .action = abi.ACTION_ADVANCE,
                    .target = n.id,
                    .priority = UTILITY_ADVANCE,
                    .speed = abi.FX_ONE,
                    .move_x = @intCast(n.bearing_cos),
                    .move_y = @intCast(n.bearing_sin),
                    .look_x = @intCast(n.bearing_cos),
                    .look_y = @intCast(n.bearing_sin),
                };
            }
            // Nothing visible and nothing remembered: v0's walk, with no target.
            return .{
                .action = abi.ACTION_ADVANCE,
                .target = 0,
                .priority = UTILITY_ADVANCE,
                .speed = abi.FX_ONE,
                .move_x = 0,
                .move_y = 0,
                .look_x = 0,
                .look_y = 0,
            };
        },

        else => return .{
            .action = abi.ACTION_HOLD,
            .target = 0,
            .priority = 0,
            .speed = 0,
            .move_x = 0,
            .move_y = 0,
            .look_x = 0,
            .look_y = 0,
        },
    }
}

// ── The tick ────────────────────────────────────────────────────────────────

// ── Perception memory (Phase 2, ADR-0009) ───────────────────────────────────
// Where the memory lives, why no layout moved, and what each slot means: see
// Abi.Memory's header and ADR-0009. In one line: the memory is a DIRECTION and an
// age, and it is stored in the fields `ee_agent` has carried unused since v0.

/// Is there a direction worth walking along?
///
/// The comparison is against `abi.memory_ttl`, the constant Abi.Gen emits from the
/// model — the same 36 that `Abi.Memory`'s theorems pin (`freshJustBeforeTtl`,
/// `staleAtTtl`). The kernel does not get to have its own idea of the TTL.
fn memoryFresh(agent: *const abi.EeAgent) bool {
    return (agent.flags & abi.AGENT_FLAG_MEMORY_VALID) != 0 and
        agent.memory_age < abi.memory_ttl;
}

/// Forgetting clears the payload rather than only lowering the flag: a forgotten
/// memory that still held a direction is one bug away from steering an agent at a
/// contact that is two minutes stale. `Abi.Memory.forgottenHoldsNothing` says the
/// same thing about the model, and this is the code it is talking about.
fn forget(agent: *abi.EeAgent) void {
    agent.flags &= ~abi.AGENT_FLAG_MEMORY_VALID;
    agent.memory_x = 0;
    agent.memory_y = 0;
    agent.memory_age = 0;
}

/// A tick in which nothing was seen: the age advances, and at the TTL the memory
/// is forgotten — `age + 1 < ttl` keeps it, equality or past it forgets. The
/// boundary is the TTL itself, so "still actionable one tick short of it, gone at
/// it" holds in the kernel exactly as `Abi.Memory` proves it of the model.
fn ageMemory(agent: *abi.EeAgent) void {
    if ((agent.flags & abi.AGENT_FLAG_MEMORY_VALID) == 0) return;
    if (agent.memory_age +% 1 < abi.memory_ttl) {
        agent.memory_age +%= 1;
        return;
    }
    forget(agent);
}

/// Walk towards where the contact was. The remembered id is REPORTED, never
/// dereferenced: the kernel holds no pointers into host memory and cannot follow a
/// stale id anywhere.
fn investigate(agent: *const abi.EeAgent) Decision {
    return .{
        .action = abi.ACTION_INVESTIGATE,
        .target = agent.cached_target,
        .priority = 32768, // 0.50 — between advance (0.40) and attack (0.80)
        .speed = abi.FX_ONE,
        .move_x = agent.memory_x,
        .move_y = agent.memory_y,
        .look_x = agent.memory_x,
        .look_y = agent.memory_y,
    };
}

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

    const near = nearestContact(snap);

    // The memory a tick DECIDES with is the one it carried in; the time it spends
    // is accounted for on the way out. The graph reads `memoryFresh(agent)` here,
    // BEFORE the bookkeeping below — that ordering is what makes this code and
    // `Abi.Memory.decideWithMemory` one rule rather than two similar ones.
    const d = decide(snap, agent);

    // An intent that came from memory says so. INVESTIGATE scores above zero only
    // when there is no contact AND the memory is fresh, so being chosen is the
    // same test the old flag performed — without a second variable to keep in step
    // with the action.
    const from_memory = d.action == abi.ACTION_INVESTIGATE;

    if (near) |n| {
        // The most recent look is the best one: the direction is overwritten and
        // the age resets. The id needs no field of its own — `cached_target` is
        // about to be written with it from the same decision.
        agent.memory_x = @as(i32, n.bearing_cos);
        agent.memory_y = @as(i32, n.bearing_sin);
        agent.memory_age = 0;
        agent.flags |= abi.AGENT_FLAG_MEMORY_VALID;
    } else {
        ageMemory(agent);
    }

    var flags: u32 = 0;
    if (degraded) flags |= abi.INTENT_FLAG_DEGRADED;
    if (agent.cached_target != d.target) flags |= abi.INTENT_FLAG_NEW_TARGET;
    if (from_memory) flags |= abi.INTENT_FLAG_FROM_MEMORY;

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
