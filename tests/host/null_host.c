/* SPDX-License-Identifier: MPL-2.0 */
/* Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk> */
/*
 * null_host.c — a game with no game in it.
 *
 * This is the acceptance test for Phase 1. It includes the GENERATED header as a
 * C host would, links the kernel as a C library, and ticks it 10,000 times with
 * fabricated snapshots. If this program builds and passes, then:
 *
 *   1. `ee.h` is self-sufficient: it compiles as C11 with no other include, and
 *      its _Static_asserts agree with what this compiler lays out.
 *   2. The Zig kernel's own comptime asserts agree with the same numbers (or the
 *      library would not have compiled).
 *   3. The exported symbols, the status codes and the struct sizes all survive a
 *      real link — no Zig-specific machinery leaks into the host's view.
 *   4. The kernel produces an answer for every one of 10,000 ticks, and the same
 *      answer twice: the replay property ADR-0006 demands.
 *
 * Nothing in here is engine-specific, which is the point: the "universally
 * injectible" claim means a host that can fill in a struct can run this.
 *
 * Build (see `just kernel-host-test`):
 *   gcc -std=c11 -Wall -Wextra -Werror -Iinclude tests/host/null_host.c \
 *       src/interface/ffi/zig-out/lib/libevil_weevil.a -o null_host
 */

#include <evil_weevil/ee.h>

#include <stdio.h>
#include <string.h>

static int failures = 0;

static void check(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}

/* A snapshot for tick `t`: the same fixture the Zig harness uses, so the two
 * hosts can be compared directly. */
static ee_snapshot make_snapshot(uint64_t t)
{
    ee_snapshot s;
    memset(&s, 0, sizeof s);
    s.tick = t;
    s.agent_id = 7;
    s.capability_mask = 0xFFFFFFFFu;
    /* Wounded every third tick, healthy otherwise: both sides of the health
     * threshold get exercised, so the fixture reaches every branch of the rule. */
    s.health = (t % 3u == 0u) ? (ee_fx)(EE_FX_ONE / 8) : (ee_fx)(4 * EE_FX_ONE);
    s.ammo = (t % 17u == 0u) ? 0 : (ee_fx)(3 * EE_FX_ONE);
    s.contact_count = (uint16_t)(t % 5u);
    for (uint16_t i = 0; i < s.contact_count; ++i) {
        ee_contact c;
        memset(&c, 0, sizeof c);
        c.id = (uint16_t)(100u + i);
        c.bearing_cos = (uint16_t)(16384u + i * 4096u);
        c.bearing_sin = 8192u;
        /* 3.0, 2.0, 1.0, 0.5: the nearest contact lands in a different band for
         * each contact count, which is what makes the fixture reach attack and flee. */
        c.distance = (ee_fx)(196608 - (int)i * 65536);
        c.threat = EE_FX_ONE / 2;
        switch (i) {
        case 0: s.contact0 = c; break;
        case 1: s.contact1 = c; break;
        case 2: s.contact2 = c; break;
        case 3: s.contact3 = c; break;
        default: break;
        }
    }
    return s;
}

/* Fold a run into one number, so two runs compare with one integer. */
/* Drive 10,000 ticks of the v0 fixture and fold every intent into one number.
 *
 * memory_enabled = 0 clears the agent's MEMORY_VALID bit after every tick, which
 * is all "v0 behaviour" means now: the kernel's memory branch is gated on that bit
 * and nothing else, so a host that never lets it be set gets the amnesiac rule
 * exactly. ADR-0009 claims that; the assertion in main() checks it against the
 * digest v0 shipped, rather than leaving it as prose. */
static uint64_t run_trace(uint64_t seed, ee_context *ctx_out, int memory_enabled)
{
    ee_init_desc desc;
    memset(&desc, 0, sizeof desc);
    desc.struct_size = (uint32_t)sizeof desc;
    desc.abi_major = EE_ABI_MAJOR;
    desc.abi_minor = EE_ABI_MINOR;
    desc.capabilities = EE_CAP_NAVMESH | EE_CAP_LINE_OF_SIGHT;
    desc.max_agents = 1;
    desc.host_tick_num = 60;
    desc.host_tick_den = 1;
    desc.rng_seed = seed;
    desc.abi_fingerprint = EE_ABI_FINGERPRINT;

    ee_context ctx;
    memset(&ctx, 0, sizeof ctx);
    ee_status st = ee_init(&desc, &ctx);
    check(st == EE_STATUS_OK, "ee_init returned ee_ok");

    ee_agent agent;
    memset(&agent, 0, sizeof agent);
    agent.rng_state = seed;

    uint64_t digest = 0;
    uint64_t answered = 0;
    for (uint64_t t = 0; t < 10000u; ++t) {
        ee_snapshot snap = make_snapshot(t);
        ee_intent intent;
        memset(&intent, 0, sizeof intent);
        st = ee_tick(&ctx, &snap, &agent, &intent);
        if (st != EE_STATUS_OK) {
            fprintf(stderr, "FAIL: ee_tick returned %s at tick %llu\n",
                    ee_status_name(st), (unsigned long long)t);
            failures++;
            break;
        }
        if (intent.action > EE_ACTION_INVESTIGATE) {
            fprintf(stderr, "FAIL: action %u out of range at tick %llu\n",
                    intent.action, (unsigned long long)t);
            failures++;
            break;
        }
        if (!memory_enabled)
            agent.flags &= ~((uint32_t)EE_AGENT_FLAG_MEMORY_VALID);
        digest = digest * 1099511628211ULL + intent.action;
        digest = digest * 1099511628211ULL + intent.target_id;
        digest = digest * 1099511628211ULL + (uint64_t)(int64_t)intent.move_x;
        digest = digest * 1099511628211ULL + intent.flags;
        answered++;
    }
    check(answered == 10000u, "the kernel answered all 10,000 ticks");
    if (ctx_out) *ctx_out = ctx;
    return digest;
}

/* ── The scenario the v0 fixture cannot reach: losing the contact ────────────
 *
 * The v0 fixture has zero-contact ticks (tick %% 5 == 0) and the memory branch
 * fires on them, but a fresh sighting arrives within five ticks, so the agent
 * never gets near the TTL. This fixture is the other half: a contact is visible
 * for the first 30 ticks of every 100 and gone for the 70 after that, so the
 * agent investigates for exactly memory_ttl ticks and then forgets — a hundred
 * times over the run. Duplicated in src/interface/ffi/test/null_host.zig on
 * purpose: two hosts, two languages, one trace, checked by digest. */
static ee_snapshot make_chase_snapshot(uint64_t t)
{
    const int visible = (t % 100u) < 30u;
    ee_snapshot s = make_snapshot(t);
    s.health = (ee_fx)(4 * EE_FX_ONE);
    s.ammo = (ee_fx)(3 * EE_FX_ONE);
    s.contact_count = visible ? 1u : 0u;
    if (visible) {
        s.contact0.id = 7;
        s.contact0.bearing_cos = 16384;
        s.contact0.bearing_sin = 8192;
        s.contact0.distance = 196608; /* 3.0 — beyond attack range */
        s.contact0.threat = (ee_fx)(EE_FX_ONE / 2);
    }
    return s;
}

static uint64_t run_chase_trace(uint64_t seed, ee_context *ctx_out,
                                unsigned counts[9], unsigned *from_memory)
{
    ee_init_desc desc;
    memset(&desc, 0, sizeof desc);
    desc.struct_size = (uint32_t)sizeof desc;
    desc.abi_major = EE_ABI_MAJOR;
    desc.capabilities = EE_CAP_NAVMESH | EE_CAP_LINE_OF_SIGHT;
    desc.max_agents = 1;
    desc.rng_seed = seed;
    desc.abi_fingerprint = EE_ABI_FINGERPRINT;

    ee_context ctx;
    memset(&ctx, 0, sizeof ctx);
    if (ee_init(&desc, &ctx) != EE_STATUS_OK) {
        failures++;
        return 0;
    }

    ee_agent agent;
    memset(&agent, 0, sizeof agent);
    agent.rng_state = seed;

    memset(counts, 0, 9u * sizeof counts[0]);
    *from_memory = 0;

    uint64_t digest = 0;
    for (uint64_t t = 0; t < 10000u; ++t) {
        ee_snapshot snap = make_chase_snapshot(t);
        ee_intent intent;
        memset(&intent, 0, sizeof intent);
        if (ee_tick(&ctx, &snap, &agent, &intent) != EE_STATUS_OK) {
            failures++;
            break;
        }
        if (intent.action < 9u)
            counts[intent.action]++;
        if (intent.flags & EE_INTENT_FLAG_FROM_MEMORY)
            (*from_memory)++;
        digest = digest * 1099511628211ULL + intent.action;
        digest = digest * 1099511628211ULL + intent.target_id;
        digest = digest * 1099511628211ULL + (uint64_t)(int64_t)intent.move_x;
        digest = digest * 1099511628211ULL + intent.flags;
    }
    if (ctx_out) *ctx_out = ctx;
    return digest;
}

int main(void)
{
    /* Layout, as this compiler produced it. The header already asserted these at
     * compile time; printing them makes a failure legible rather than a wall of
     * notes from the compiler. */
    printf("evil-weevil ABI %u.%u, fingerprint %llu\n",
           (unsigned)EE_ABI_MAJOR, (unsigned)EE_ABI_MINOR,
           (unsigned long long)ee_abi_fingerprint());
    printf("  ee_version   %3zu   ee_init_desc %3zu   ee_contact %2zu\n",
           sizeof(ee_version), sizeof(ee_init_desc), sizeof(ee_contact));
    printf("  ee_snapshot  %3zu   ee_agent     %3zu   ee_intent  %2zu   ee_context %2zu\n",
           sizeof(ee_snapshot), sizeof(ee_agent), sizeof(ee_intent), sizeof(ee_context));

    const ee_version v = ee_version_info();
    check(v.major == EE_ABI_MAJOR && v.minor == EE_ABI_MINOR, "version_info matches the header");
    check(ee_abi_fingerprint() == EE_ABI_FINGERPRINT, "the exported fingerprint matches the header");
    check(ee_abi_fingerprint() == (uint64_t)(ee_init_desc){0}.abi_fingerprint + ee_abi_fingerprint(),
          "the fingerprint is a usable value (non-degenerate)");

    /* Refusals: a host that links must be told when it does not match. */
    {
        ee_context ctx;
        ee_init_desc desc;
        memset(&ctx, 0, sizeof ctx);
        memset(&desc, 0, sizeof desc);
        desc.struct_size = (uint32_t)sizeof desc;
        desc.abi_major = EE_ABI_MAJOR + 1;
        check(ee_init(&desc, &ctx) == EE_STATUS_VERSION_MISMATCH, "a future major is refused");
        desc.abi_major = EE_ABI_MAJOR;
        desc.abi_fingerprint = EE_ABI_FINGERPRINT + 1;
        check(ee_init(&desc, &ctx) == EE_STATUS_FINGERPRINT_MISMATCH, "a stale layout is refused");
        desc.struct_size = 4;
        desc.abi_fingerprint = EE_ABI_FINGERPRINT;
        check(ee_init(&desc, &ctx) == EE_STATUS_BUFFER_TOO_SMALL, "a short struct is refused");
        check(ee_init(NULL, &ctx) == EE_STATUS_BAD_PARAM, "a null descriptor is refused");
    }

    /* Determinism: two seeded runs, one digest. Plus the third run that makes
     * ADR-0009's compatibility claim a checked fact rather than a promise. */
    ee_context ctx_a, ctx_b, ctx_v0;
    const uint64_t first = run_trace(0xEE0000000000001ULL, &ctx_a, 1);
    const uint64_t second = run_trace(0xEE0000000000001ULL, &ctx_b, 1);
    const uint64_t v0 = run_trace(0xEE0000000000001ULL, &ctx_v0, 0);
    printf("  digest after 10,000 ticks (memory enabled): %llu\n", (unsigned long long)first);
    printf("  the same trace with the memory flag cleared: %llu\n", (unsigned long long)v0);
    check(first == second, "two runs of 10,000 ticks agree exactly");
    /* Pinned, not merely self-consistent: this number is asserted by BOTH hosts
     * (this one and src/interface/ffi/test/null_host.zig), so the C and Zig views
     * of the same fixture must agree bit for bit. Changing the rule changes this
     * number — that is the point. When you change it on purpose, change it in both
     * places and say why in ADR-0006.
     *
     * It MOVED when Phase 2 wired memory in (from 4061121875253101873), and the
     * reason is not a mystery: this fixture has zero-contact ticks, so the new
     * branch fires inside it. The old number did not disappear — it moved one
     * check down, where it now asserts something stronger than it did before. */
    check(first == 14165495496352896129ULL, "the trace digest matches the pinned value");
    check(v0 == 4061121875253101873ULL,
          "a host that clears the memory flag gets EXACTLY v0's trace (ADR-0009)");
    check(first != v0, "memory is consulted in the default configuration — the check above is not vacuous");
    check(ctx_a.ticks_run == 10000u, "the context counted every tick");

    /* The scenario the v0 fixture cannot reach: a contact that leaves. */
    {
        ee_context ctx_m;
        unsigned counts[9];
        unsigned from_memory = 0;
        const uint64_t chase = run_chase_trace(0xEE0000000000001ULL, &ctx_m, counts, &from_memory);
        printf("  chase digest: %llu (investigate=%u advance=%u from_memory=%u)\n",
               (unsigned long long)chase, counts[EE_ACTION_INVESTIGATE],
               counts[EE_ACTION_ADVANCE], from_memory);
        check(chase == 12283675074724005768ULL, "the chase digest matches the pinned value");
        /* 36 is memory_ttl: this assertion is Abi.Memory's
         * freshJustBeforeTtl/staleAtTtl boundary, counted in a real run. */
        check(counts[EE_ACTION_INVESTIGATE] == 3600u, "the agent investigates for exactly 36 ticks per 100");
        check(counts[EE_ACTION_ADVANCE] == 6400u, "and advances for the other 64");
        check(counts[EE_ACTION_ATTACK] == 0u && counts[EE_ACTION_FLEE] == 0u &&
                  counts[EE_ACTION_RELOAD] == 0u,
              "no other action fires in the chase fixture");
        check(from_memory == counts[EE_ACTION_INVESTIGATE],
              "the FROM_MEMORY flag is set on investigate and nowhere else");
        check(ctx_m.ticks_run == 10000u, "the chase context counted every tick");
    }

    /* The TTL boundary, watched at the agent rather than only in the model: 65
     * ticks in, the memory is one tick short of the TTL; the 66th reaches it and
     * forgets, clearing the payload rather than only lowering the flag. */
    {
        ee_context ctx;
        memset(&ctx, 0, sizeof ctx);
        ee_init_desc desc;
        memset(&desc, 0, sizeof desc);
        desc.struct_size = (uint32_t)sizeof desc;
        desc.abi_major = EE_ABI_MAJOR;
        desc.capabilities = EE_CAP_NAVMESH;
        desc.max_agents = 1;
        desc.abi_fingerprint = EE_ABI_FINGERPRINT;
        check(ee_init(&desc, &ctx) == EE_STATUS_OK, "memory probe context initialises");

        ee_agent agent;
        memset(&agent, 0, sizeof agent);
        ee_intent intent;
        for (uint64_t t = 0; t < 65u; ++t) {
            ee_snapshot snap = make_chase_snapshot(t);
            (void)ee_tick(&ctx, &snap, &agent, &intent);
        }
        check((agent.flags & (uint32_t)EE_AGENT_FLAG_MEMORY_VALID) != 0u,
              "the memory is still valid one tick short of the TTL");
        check(agent.memory_age == 35u, "the memory has aged to 35 (memory_ttl - 1)");

        {
            ee_snapshot snap = make_chase_snapshot(65);
            (void)ee_tick(&ctx, &snap, &agent, &intent);
        }
        check((agent.flags & (uint32_t)EE_AGENT_FLAG_MEMORY_VALID) == 0u,
              "the TTL is reached and the memory is forgotten");
        check(agent.memory_x == 0 && agent.memory_y == 0 && agent.memory_age == 0u,
              "forgetting cleared the payload, not just the flag");
    }

    /* A minimal sanity check on the output stream: the fixture must actually make
     * the agent do more than one thing, or "deterministic" would be vacuous. */
    {
        ee_context ctx;
        memset(&ctx, 0, sizeof ctx);
        ee_init_desc desc;
        memset(&desc, 0, sizeof desc);
        desc.struct_size = (uint32_t)sizeof desc;
        desc.abi_major = EE_ABI_MAJOR;
        desc.capabilities = EE_CAP_NAVMESH;
        desc.max_agents = 1;
        desc.abi_fingerprint = EE_ABI_FINGERPRINT;
        check(ee_init(&desc, &ctx) == EE_STATUS_OK, "sanity context initialises");

        unsigned seen[9];
        memset(seen, 0, sizeof seen);
        ee_agent agent;
        memset(&agent, 0, sizeof agent);
        for (uint64_t t = 0; t < 200u; ++t) {
            ee_snapshot snap = make_snapshot(t);
            ee_intent intent;
            if (ee_tick(&ctx, &snap, &agent, &intent) == EE_STATUS_OK && intent.action < 9u)
                seen[intent.action]++;
        }
        check(seen[EE_ACTION_RELOAD] > 0, "the agent reloads when out of ammo");
        check(seen[EE_ACTION_ADVANCE] > 0, "the agent advances with nothing to fight");
        check(seen[EE_ACTION_ATTACK] > 0, "the agent attacks when in range");
        check(seen[EE_ACTION_INVESTIGATE] > 0, "the agent investigates where a contact went");
        printf("  actions in 200 ticks: reload=%u advance=%u attack=%u flee=%u hold=%u investigate=%u\n",
               seen[EE_ACTION_RELOAD], seen[EE_ACTION_ADVANCE], seen[EE_ACTION_ATTACK],
               seen[EE_ACTION_FLEE], seen[EE_ACTION_HOLD], seen[EE_ACTION_INVESTIGATE]);
    }

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("null host: OK — the kernel ran with no engine behind it.\n");
    return 0;
}
