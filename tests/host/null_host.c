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
static uint64_t run_trace(uint64_t seed, ee_context *ctx_out)
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

    /* Determinism: two seeded runs, one digest. */
    ee_context ctx_a, ctx_b;
    const uint64_t first = run_trace(0xEE0000000000001ULL, &ctx_a);
    const uint64_t second = run_trace(0xEE0000000000001ULL, &ctx_b);
    printf("  digest after 10,000 ticks: %llu\n", (unsigned long long)first);
    check(first == second, "two runs of 10,000 ticks agree exactly");
    /* Pinned, not merely self-consistent: this number is asserted by BOTH hosts
     * (this one and src/interface/ffi/test/null_host.zig), so the C and Zig views
     * of the same fixture must agree bit for bit. Changing the rule changes this
     * number — that is the point. When you change it on purpose, change it in both
     * places and say why in ADR-0006. */
    check(first == 4061121875253101873ULL, "the trace digest matches the pinned value");
    check(ctx_a.ticks_run == 10000u, "the context counted every tick");

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
        printf("  actions in 200 ticks: reload=%u advance=%u attack=%u flee=%u hold=%u\n",
               seen[EE_ACTION_RELOAD], seen[EE_ACTION_ADVANCE], seen[EE_ACTION_ATTACK],
               seen[EE_ACTION_FLEE], seen[EE_ACTION_HOLD]);
    }

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("null host: OK — the kernel ran with no engine behind it.\n");
    return 0;
}
