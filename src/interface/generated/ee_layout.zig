// SPDX-License-Identifier: MPL-2.0
//
// GENERATED FILE — DO NOT EDIT BY HAND.
// Emitted by Abi.Gen from the same model as include/evil_weevil/ee.h.
// Regenerate: just abi-gen    Verify: just abi-check
//
// The Zig kernel asserts its own @sizeOf/@offsetOf against these at comptime,
// so a struct that drifts from the C ABI fails the BUILD rather than corrupting
// a host's memory at runtime.

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 0;
pub const abi_fingerprint: u64 = 18276775;
pub const fx_fraction_bits: u32 = 16;
pub const fx_one: i32 = 65536;

// Capability bits, status codes and action codes — the same numbers the C
// header defines, emitted from the same model so the two cannot disagree.
pub const CAP_NAVMESH: u32 = 1; // bit 0
pub const CAP_LINE_OF_SIGHT: u32 = 2; // bit 1
pub const CAP_RAYCAST: u32 = 4; // bit 2
pub const CAP_WAYPOINT_GRAPH: u32 = 8; // bit 3
pub const CAP_SPAWN_RIGHTS: u32 = 16; // bit 4
pub const CAP_ANIMATION_HOOKS: u32 = 32; // bit 5
pub const CAP_DAMAGE_EVENTS: u32 = 64; // bit 6
pub const CAP_SOUND_EVENTS: u32 = 128; // bit 7
pub const CAP_VEHICLE_BOARDING: u32 = 256; // bit 8
pub const CAP_TERRAIN_HEIGHT: u32 = 512; // bit 9

pub const STATUS_OK: u32 = 0;
pub const STATUS_BAD_PARAM: u32 = 1;
pub const STATUS_VERSION_MISMATCH: u32 = 2;
pub const STATUS_FINGERPRINT_MISMATCH: u32 = 3;
pub const STATUS_CAPABILITY_UNSUPPORTED: u32 = 4;
pub const STATUS_BUFFER_TOO_SMALL: u32 = 5;
pub const STATUS_PANIC_CAUGHT: u32 = 6;

pub const ACTION_IDLE: u32 = 0;
pub const ACTION_ADVANCE: u32 = 1;
pub const ACTION_HOLD: u32 = 2;
pub const ACTION_FLEE: u32 = 3;
pub const ACTION_ATTACK: u32 = 4;
pub const ACTION_RELOAD: u32 = 5;
pub const ACTION_TAKE_COVER: u32 = 6;
pub const ACTION_REGROUP: u32 = 7;
pub const ACTION_INVESTIGATE: u32 = 8;

pub const INTENT_FLAG_DEGRADED: u32 = 1;
pub const INTENT_FLAG_NEW_TARGET: u32 = 2;
pub const INTENT_FLAG_UNREACHABLE: u32 = 4;
pub const INTENT_FLAG_FROM_MEMORY: u32 = 8;
pub const memory_ttl: u32 = 36;

pub const sizeof_ee_version: usize = 8;
pub const offset_ee_version_major: usize = 0;
pub const offset_ee_version_minor: usize = 2;
pub const offset_ee_version_patch: usize = 4;
pub const offset_ee_version_reserved: usize = 6;
pub const sizeof_ee_init_desc: usize = 64;
pub const offset_ee_init_desc_struct_size: usize = 0;
pub const offset_ee_init_desc_abi_major: usize = 4;
pub const offset_ee_init_desc_abi_minor: usize = 8;
pub const offset_ee_init_desc_capabilities: usize = 12;
pub const offset_ee_init_desc_max_agents: usize = 16;
pub const offset_ee_init_desc_flags: usize = 20;
pub const offset_ee_init_desc_host_tick_num: usize = 24;
pub const offset_ee_init_desc_host_tick_den: usize = 32;
pub const offset_ee_init_desc_rng_seed: usize = 40;
pub const offset_ee_init_desc_abi_fingerprint: usize = 48;
pub const offset_ee_init_desc_reserved0: usize = 56;
pub const sizeof_ee_contact: usize = 16;
pub const offset_ee_contact_id: usize = 0;
pub const offset_ee_contact_flags: usize = 2;
pub const offset_ee_contact_bearing_cos: usize = 4;
pub const offset_ee_contact_bearing_sin: usize = 6;
pub const offset_ee_contact_distance: usize = 8;
pub const offset_ee_contact_threat: usize = 12;
pub const sizeof_ee_snapshot: usize = 184;
pub const offset_ee_snapshot_tick: usize = 0;
pub const offset_ee_snapshot_capability_mask: usize = 8;
pub const offset_ee_snapshot_agent_id: usize = 12;
pub const offset_ee_snapshot_contact_count: usize = 14;
pub const offset_ee_snapshot_self_x: usize = 16;
pub const offset_ee_snapshot_self_y: usize = 20;
pub const offset_ee_snapshot_self_z: usize = 24;
pub const offset_ee_snapshot_self_vx: usize = 28;
pub const offset_ee_snapshot_self_vy: usize = 32;
pub const offset_ee_snapshot_health: usize = 36;
pub const offset_ee_snapshot_ammo: usize = 40;
pub const offset_ee_snapshot_flags: usize = 44;
pub const offset_ee_snapshot_contact0: usize = 48;
pub const offset_ee_snapshot_contact1: usize = 64;
pub const offset_ee_snapshot_contact2: usize = 80;
pub const offset_ee_snapshot_contact3: usize = 96;
pub const offset_ee_snapshot_contact4: usize = 112;
pub const offset_ee_snapshot_contact5: usize = 128;
pub const offset_ee_snapshot_contact6: usize = 144;
pub const offset_ee_snapshot_contact7: usize = 160;
pub const offset_ee_snapshot_cooldown: usize = 176;
pub const offset_ee_snapshot_reserved0: usize = 180;
pub const sizeof_ee_agent: usize = 48;
pub const offset_ee_agent_rng_state: usize = 0;
pub const offset_ee_agent_tick_last: usize = 8;
pub const offset_ee_agent_memory_x: usize = 16;
pub const offset_ee_agent_memory_y: usize = 20;
pub const offset_ee_agent_memory_age: usize = 24;
pub const offset_ee_agent_cached_action: usize = 28;
pub const offset_ee_agent_cached_target: usize = 32;
pub const offset_ee_agent_budget_used: usize = 36;
pub const offset_ee_agent_degraded_ticks: usize = 40;
pub const offset_ee_agent_flags: usize = 44;
pub const sizeof_ee_intent: usize = 48;
pub const offset_ee_intent_action: usize = 0;
pub const offset_ee_intent_target_id: usize = 4;
pub const offset_ee_intent_move_x: usize = 8;
pub const offset_ee_intent_move_y: usize = 12;
pub const offset_ee_intent_move_z: usize = 16;
pub const offset_ee_intent_look_x: usize = 20;
pub const offset_ee_intent_look_y: usize = 24;
pub const offset_ee_intent_speed: usize = 28;
pub const offset_ee_intent_priority: usize = 32;
pub const offset_ee_intent_budget_used: usize = 36;
pub const offset_ee_intent_flags: usize = 40;
pub const offset_ee_intent_reserved0: usize = 44;
pub const sizeof_ee_context: usize = 72;
pub const offset_ee_context_abi_major: usize = 0;
pub const offset_ee_context_flags: usize = 4;
pub const offset_ee_context_capabilities: usize = 8;
pub const offset_ee_context_budget_units: usize = 12;
pub const offset_ee_context_max_agents: usize = 16;
pub const offset_ee_context_reserved0: usize = 20;
pub const offset_ee_context_abi_fingerprint: usize = 24;
pub const offset_ee_context_rng_seed: usize = 32;
pub const offset_ee_context_tick_rate_num: usize = 40;
pub const offset_ee_context_tick_rate_den: usize = 48;
pub const offset_ee_context_ticks_run: usize = 56;
pub const offset_ee_context_degraded_ticks: usize = 64;
