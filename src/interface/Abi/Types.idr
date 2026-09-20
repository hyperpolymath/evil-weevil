-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
||| Evil Weevil ABI v0 — the type model.
|||
||| This module is the SINGLE SOURCE OF TRUTH for the C ABI. `Abi.Gen` reads the
||| field lists below and emits both `include/evil_weevil/ee.h` and
||| `src/interface/generated/ee_layout.zig` from them; `Abi.Layout` proves the
||| offsets and sizes computed from the same lists. Nothing about the wire format
||| is written down twice, and no constant in the header is hand-typed.
|||
||| Two design rules make the whole thing checkable (ADR-0005):
|||
|||   1. NO POINTER-SIZED FIELD appears in any struct crossing the ABI. Pointers
|||      appear only as function PARAMETERS. This keeps the layout identical on
|||      every 64-bit target and keeps host addresses out of deterministic state.
|||   2. Field order is descending by alignment, with explicit pad fields where
|||      padding would otherwise be implicit. The declared offsets therefore equal
|||      C's natural layout, which C's own `_Static_assert`s then verify per
|||      compiler (see the generated header).
|||
||| Idris2 cannot reduce `map` in a proof position, so the size lists below are
||| written out literally beside each named field list. That duplication is not
||| decorative: the generator cross-checks the two at runtime and exits non-zero on
||| any divergence, so a field added to one and not the other fails `just abi-check`
||| rather than silently reshaping the ABI.

module Abi.Types

import Data.Nat
import Data.So

%default total

--------------------------------------------------------------------------------
-- Platform model
--------------------------------------------------------------------------------

||| Targets this ABI layout is validated for.
|||
||| 32-bit targets (including wasm32) are deliberately ABSENT. Idris2's layout
||| model below is 64-bit; claiming wasm32 compat without re-deriving it would be
||| exactly the kind of unverified claim this repo exists to avoid. A 32-bit
||| variant is Phase 4 work with its own layout proofs.
public export
data Platform = Linux64 | MacOS64 | Windows64

||| Pointer size in bytes per platform (all current targets are 64-bit).
public export
ptrBytes : Platform -> Nat
ptrBytes Linux64 = 8
ptrBytes MacOS64 = 8
ptrBytes Windows64 = 8

--------------------------------------------------------------------------------
-- C type model
--------------------------------------------------------------------------------

||| The C-level types the ABI is built from. Sizes and alignments are the
||| System V / Windows x86-64 values for the fixed-width types plus the two
||| composite types this ABI defines.
public export
data CType = U8 | U16 | U32 | U64 | I32 | I64 | Fx | CVersion | CContact

public export
sizeOf : CType -> Nat
sizeOf U8 = 1
sizeOf U16 = 2
sizeOf U32 = 4
sizeOf U64 = 8
sizeOf I32 = 4
sizeOf I64 = 8
sizeOf Fx = 4
sizeOf CVersion = 8
sizeOf CContact = 16

public export
alignOf : CType -> Nat
alignOf U8 = 1
alignOf U16 = 2
alignOf U32 = 4
alignOf U64 = 8
alignOf I32 = 4
alignOf I64 = 8
alignOf Fx = 4
alignOf CVersion = 2
alignOf CContact = 4

--------------------------------------------------------------------------------
-- Fixed point
--------------------------------------------------------------------------------

||| All kernel arithmetic is integer/fixed-point (ADR-0006). This is Q16.16 in an
||| i32: range ±32768, resolution 1/65536. Named export so the header documents it
||| and so a future Q32.32 widening is a visible change, not a silent one.
public export
fxFractionBits : Nat
fxFractionBits = 16

public export
fxOne : Nat
fxOne = 65536

||| The scaling factor (2^16 = 65536, the `fxOne` above) is comfortably inside
||| i32 range, so Q16.16 is representable at all. Written with literals because
||| Idris2 does not unfold a top-level constant in a proof position; the tie to
||| `fxOne` is the definition above, which is textual rather than derived.
export
fxOneFitsI32 : So (65536 < 2147483647)
fxOneFitsI32 = Oh

--------------------------------------------------------------------------------
-- Version and handshake
--------------------------------------------------------------------------------

public export
record Version where
  constructor MkVersion
  major : Nat
  minor : Nat
  patch : Nat

||| The ABI version this kernel implements. Bumping `major` is a breaking change
||| and requires a new ADR; `minor` is additive (ADR-0005).
public export
abiVersion : Version
abiVersion = MkVersion 1 0 0

public export
data Handshake
  = Compatible
  | HostTooOld
  | HostTooNew
  | FingerprintMismatch

||| The handshake decision, as a total function of the two versions.
||| Total means every input has an answer: there is no input for which the kernel
||| "forgets" to reply, and the compiler checks that (ADR-0005 §3).
public export
negotiate : (kernel : Version) -> (host : Version) -> Handshake
negotiate (MkVersion kmaj _ _) (MkVersion hmaj _ _) =
  if hmaj == kmaj
     then Compatible
     else if hmaj < kmaj
             then HostTooOld
             else HostTooNew

||| Concrete behaviour of the handshake, proved rather than asserted in prose.
||| Literals rather than `abiVersion` for the reason given at `fxOneFitsI32`.
export
sameVersionCompatible : negotiate (MkVersion 1 0 0) (MkVersion 1 0 0) = Compatible
sameVersionCompatible = Refl

export
olderHostRejected : negotiate (MkVersion 2 0 0) (MkVersion 1 0 0) = HostTooOld
olderHostRejected = Refl

export
newerHostRejected : negotiate (MkVersion 1 0 0) (MkVersion 2 0 0) = HostTooNew
newerHostRejected = Refl

--------------------------------------------------------------------------------
-- Status codes
--------------------------------------------------------------------------------

||| Every entry point returns one of these. Codes are part of the ABI: the numbers
||| are emitted into the header, and `statusCode` is total, so adding a constructor
||| without a code is a compile error rather than an unhandled case at runtime.
public export
data Status
  = EeOk
  | EeBadParam
  | EeVersionMismatch
  | EeFingerprintMismatch
  | EeCapabilityUnsupported
  | EeBufferTooSmall
  | EePanicCaught

public export
statusCode : Status -> Nat
statusCode EeOk = 0
statusCode EeBadParam = 1
statusCode EeVersionMismatch = 2
statusCode EeFingerprintMismatch = 3
statusCode EeCapabilityUnsupported = 4
statusCode EeBufferTooSmall = 5
statusCode EePanicCaught = 6

--------------------------------------------------------------------------------
-- Host capabilities
--------------------------------------------------------------------------------

||| What a host may declare it can do. The kernel degrades along a documented
||| ladder for each absent capability rather than aborting (ADR-0004).
public export
data Capability
  = CapNavmesh
  | CapLineOfSight
  | CapRaycast
  | CapWaypointGraph
  | CapSpawnRights
  | CapAnimationHooks
  | CapDamageEvents
  | CapSoundEvents
  | CapVehicleBoarding
  | CapTerrainHeight

||| Bit index of each capability in the u32 mask.
public export
capBit : Capability -> Nat
capBit CapNavmesh = 0
capBit CapLineOfSight = 1
capBit CapRaycast = 2
capBit CapWaypointGraph = 3
capBit CapSpawnRights = 4
capBit CapAnimationHooks = 5
capBit CapDamageEvents = 6
capBit CapSoundEvents = 7
capBit CapVehicleBoarding = 8
capBit CapTerrainHeight = 9

||| Every capability fits in the 32-bit mask, proved per constructor.
||| (One case per constructor: a new capability added without checking this fails
||| to compile here, not at runtime in somebody's game.)
export
capBitFits : (c : Capability) -> So (capBit c < 32)
capBitFits CapNavmesh = Oh
capBitFits CapLineOfSight = Oh
capBitFits CapRaycast = Oh
capBitFits CapWaypointGraph = Oh
capBitFits CapSpawnRights = Oh
capBitFits CapAnimationHooks = Oh
capBitFits CapDamageEvents = Oh
capBitFits CapSoundEvents = Oh
capBitFits CapVehicleBoarding = Oh
capBitFits CapTerrainHeight = Oh

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

||| What the kernel may ask the host to do. Values are stable ABI; new actions are
||| appended, never reordered (ADR-0005 §5).
public export
data Action
  = ActIdle
  | ActAdvance
  | ActHold
  | ActFlee
  | ActAttack
  | ActReload
  | ActTakeCover
  | ActRegroup
  | ActInvestigate

public export
actionCode : Action -> Nat
actionCode ActIdle = 0
actionCode ActAdvance = 1
actionCode ActHold = 2
actionCode ActFlee = 3
actionCode ActAttack = 4
actionCode ActReload = 5
actionCode ActTakeCover = 6
actionCode ActRegroup = 7
actionCode ActInvestigate = 8

--------------------------------------------------------------------------------
-- Field lists — the ABI itself
--------------------------------------------------------------------------------

public export
versionFields : List (String, CType)
versionFields =
  [ ("major", U16), ("minor", U16), ("patch", U16), ("reserved", U16) ]

public export
initDescFields : List (String, CType)
initDescFields =
  [ ("struct_size", U32)
  , ("abi_major", U32)
  , ("abi_minor", U32)
  , ("capabilities", U32)
  , ("max_agents", U32)
  , ("flags", U32)
  , ("host_tick_num", U64)
  , ("host_tick_den", U64)
  , ("rng_seed", U64)
  , ("abi_fingerprint", U64)
  , ("reserved0", U64)
  ]

public export
contactFields : List (String, CType)
contactFields =
  [ ("id", U16)
  , ("flags", U16)
  , ("bearing_cos", U16)
  , ("bearing_sin", U16)
  , ("distance", Fx)
  , ("threat", Fx)
  ]

public export
snapshotFields : List (String, CType)
snapshotFields =
  [ ("tick", U64)
  , ("capability_mask", U32)
  , ("agent_id", U16)
  , ("contact_count", U16)
  , ("self_x", Fx)
  , ("self_y", Fx)
  , ("self_z", Fx)
  , ("self_vx", Fx)
  , ("self_vy", Fx)
  , ("health", Fx)
  , ("ammo", Fx)
  , ("flags", U32)
  , ("contact0", CContact)
  , ("contact1", CContact)
  , ("contact2", CContact)
  , ("contact3", CContact)
  , ("contact4", CContact)
  , ("contact5", CContact)
  , ("contact6", CContact)
  , ("contact7", CContact)
  , ("cooldown", U32)
  , ("reserved0", U32)
  ]

public export
agentFields : List (String, CType)
agentFields =
  [ ("rng_state", U64)
  , ("tick_last", U64)
  , ("memory_x", Fx)
  , ("memory_y", Fx)
  , ("memory_age", U32)
  , ("cached_action", U32)
  , ("cached_target", U32)
  , ("budget_used", U32)
  , ("degraded_ticks", U32)
  , ("flags", U32)
  ]

public export
intentFields : List (String, CType)
intentFields =
  [ ("action", U32)
  , ("target_id", U32)
  , ("move_x", Fx)
  , ("move_y", Fx)
  , ("move_z", Fx)
  , ("look_x", Fx)
  , ("look_y", Fx)
  , ("speed", Fx)
  , ("priority", U32)
  , ("budget_used", U32)
  , ("flags", U32)
  , ("reserved0", U32)
  ]

public export
contextFields : List (String, CType)
contextFields =
  [ ("abi_major", U32)
  , ("flags", U32)
  , ("capabilities", U32)
  , ("budget_units", U32)
  , ("max_agents", U32)
  , ("reserved0", U32)
  , ("abi_fingerprint", U64)
  , ("rng_seed", U64)
  , ("tick_rate_num", U64)
  , ("tick_rate_den", U64)
  , ("ticks_run", U64)
  , ("degraded_ticks", U64)
  ]

--------------------------------------------------------------------------------
-- The proven literal size lists
--------------------------------------------------------------------------------
-- Exactly two representations of the layout exist, and this is the second:
--
--   1. the NAMED field lists above — what a maintainer edits, with names and types;
--   2. these LITERAL size lists — what `Abi.Layout` states its theorems about,
--      because Idris2 will not reduce a name in a proof position.
--
-- They are tied by `Abi.Gen`, which recomputes (1) from the field lists and
-- refuses to emit anything unless it equals (2). Adding a field to one list and
-- not the other therefore fails `just abi-check`, naming the struct, with no file
-- written — rather than silently reshaping the ABI.

public export
snapshotSizes : List Nat
snapshotSizes =
  [ 8, 4, 2, 2, 4, 4, 4, 4, 4, 4, 4, 4
  , 16, 16, 16, 16, 16, 16, 16, 16
  , 4, 4
  ]

--------------------------------------------------------------------------------
-- Flags
--------------------------------------------------------------------------------

||| Bits in `ee_intent.flags`.
public export
IntentFlag : Type
IntentFlag = Nat

public export
intentFlagDegraded : Nat
intentFlagDegraded = 1

public export
intentFlagNewTarget : Nat
intentFlagNewTarget = 2

public export
intentFlagUnreachable : Nat
intentFlagUnreachable = 4

--------------------------------------------------------------------------------
-- Total name maps and enumerations
--------------------------------------------------------------------------------
-- Each of these PATTERN MATCHES ON EVERY CONSTRUCTOR of its type. That is the
-- point: adding a Capability, Status or Action without giving it a name here
-- fails to compile, so nothing can reach the header unnamed, and the generator
-- (which iterates the lists below) cannot silently omit it.

public export
capName : Capability -> String
capName CapNavmesh = "NAVMESH"
capName CapLineOfSight = "LINE_OF_SIGHT"
capName CapRaycast = "RAYCAST"
capName CapWaypointGraph = "WAYPOINT_GRAPH"
capName CapSpawnRights = "SPAWN_RIGHTS"
capName CapAnimationHooks = "ANIMATION_HOOKS"
capName CapDamageEvents = "DAMAGE_EVENTS"
capName CapSoundEvents = "SOUND_EVENTS"
capName CapVehicleBoarding = "VEHICLE_BOARDING"
capName CapTerrainHeight = "TERRAIN_HEIGHT"

public export
statusName : Status -> String
statusName EeOk = "OK"
statusName EeBadParam = "BAD_PARAM"
statusName EeVersionMismatch = "VERSION_MISMATCH"
statusName EeFingerprintMismatch = "FINGERPRINT_MISMATCH"
statusName EeCapabilityUnsupported = "CAPABILITY_UNSUPPORTED"
statusName EeBufferTooSmall = "BUFFER_TOO_SMALL"
statusName EePanicCaught = "PANIC_CAUGHT"

public export
actionName : Action -> String
actionName ActIdle = "IDLE"
actionName ActAdvance = "ADVANCE"
actionName ActHold = "HOLD"
actionName ActFlee = "FLEE"
actionName ActAttack = "ATTACK"
actionName ActReload = "RELOAD"
actionName ActTakeCover = "TAKE_COVER"
actionName ActRegroup = "REGROUP"
actionName ActInvestigate = "INVESTIGATE"

public export
allCapabilities : List Capability
allCapabilities =
  [ CapNavmesh, CapLineOfSight, CapRaycast, CapWaypointGraph, CapSpawnRights
  , CapAnimationHooks, CapDamageEvents, CapSoundEvents, CapVehicleBoarding
  , CapTerrainHeight ]

public export
allStatuses : List Status
allStatuses =
  [ EeOk, EeBadParam, EeVersionMismatch, EeFingerprintMismatch
  , EeCapabilityUnsupported, EeBufferTooSmall, EePanicCaught ]

public export
allActions : List Action
allActions =
  [ ActIdle, ActAdvance, ActHold, ActFlee, ActAttack, ActReload
  , ActTakeCover, ActRegroup, ActInvestigate ]

--------------------------------------------------------------------------------
-- Struct-level metadata the generator needs
--------------------------------------------------------------------------------

||| C name, struct tag and field list, in the order the header emits them.
||| A record rather than a tuple so the generator cannot confuse the two strings.
public export
record Struct where
  constructor MkStruct
  sTag : String
  sFields : List (String, CType)

public export
allStructs : List Struct
allStructs =
  [ MkStruct "ee_version" versionFields
  , MkStruct "ee_init_desc" initDescFields
  , MkStruct "ee_contact" contactFields
  , MkStruct "ee_snapshot" snapshotFields
  , MkStruct "ee_agent" agentFields
  , MkStruct "ee_intent" intentFields
  , MkStruct "ee_context" contextFields
  ]

||| The literal size list that `Abi.Layout` proves theorems about, paired with
||| the same struct, so `Abi.Gen` can cross-check named fields against proven
||| sizes without a lookup table.
public export
provenSizeLists : List (List Nat)
provenSizeLists =
  [ [2, 2, 2, 2]
  , [4, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8]
  , [2, 2, 2, 2, 4, 4]
  , [8, 4, 2, 2, 4, 4, 4, 4, 4, 4, 4, 4, 16, 16, 16, 16, 16, 16, 16, 16, 4, 4]
  , [8, 8, 4, 4, 4, 4, 4, 4, 4, 4]
  , [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
  , [4, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8, 8]
  ]
