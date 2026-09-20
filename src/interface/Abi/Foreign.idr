-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
||| Evil Weevil ABI v0 — function shapes, purity, and the reference decision rule.
|||
||| This module is the SPECIFICATION the Zig kernel implements. The decision rule
||| below is v0's whole policy: five cases over health, ammo, contacts and range.
||| It is written here as a total pure function so that (a) its purity is a fact
||| about a TYPE rather than a promise, and (b) both the C harness and the future
||| workbench can be checked against one written-down rule.
|||
||| == What "purity" is doing here
|||
||| `tickModel : Nat -> Scenario -> AgentState -> (AgentState, Intent)` has no
||| `IO` in its type. It therefore cannot read a clock, open a file, allocate, or
||| call into the host — not because a reviewer checked, but because the type
||| gives it no way to. That is the property ADR-0004 and ADR-0006 require, and
||| this is where it is stated.
|||
||| == What is NOT proved here (stated, not glossed)
|||
|||   * Realised memory layout. This module says nothing about where a compiler
|||     puts fields; `Abi.Layout` proves intent and the generated `_Static_assert`
|||     / Zig comptime asserts check reality per compiler.
|||   * Equivalence of this rule with the Zig implementation. The tie is
|||     differential: the C harness replays fixed scenarios and the resulting
|||     intent trace is pinned as a golden hash in CI, so a divergence in the Zig
|||     kernel changes the hash and fails the build. A machine-checked refinement
|||     proof is Phase 2+ work and is not claimed.
|||   * A general bound theorem for the budget guard. Concrete instances are
|||     proved (see `tickIsBudgeted`), because proving the general case needs
|||     order lemmas this module does not depend on; the golden replays cover the
|||     behaviour space meanwhile.

module Abi.Foreign

import Abi.Types
import Abi.Layout
import Data.Nat
import Data.So

%default total

--------------------------------------------------------------------------------
-- Scenario: what the host publishes, reduced to the fields the rule reads
--------------------------------------------------------------------------------

||| All values are Q16.16 fixed point held as Nat for proof purposes (the wire
||| format holds them as `ee_fx`, an i32; the kernel treats them as unsigned
||| magnitudes and the sign is carried separately, which is a Phase 2 refinement).
public export
record Scenario where
  constructor MkScenario
  health : Nat
  ammo : Nat
  contactCount : Nat
  nearestDist : Nat
  nearestId : Nat

--------------------------------------------------------------------------------
-- Agent state and intent: the ABI structs, at the semantic level
--------------------------------------------------------------------------------

public export
record AgentState where
  constructor MkAgentState
  rngState : Nat
  tickLast : Nat
  cachedAction : Action
  cachedTarget : Nat
  budgetUsed : Nat
  degradedTicks : Nat

public export
record Intent where
  constructor MkIntent
  intentAction : Action
  intentTarget : Nat
  intentBudgetUsed : Nat
  intentDegraded : Bool

--------------------------------------------------------------------------------
-- Budget guard
--------------------------------------------------------------------------------

||| Clamp to a budget. The kernel's guard uses exactly this shape: an agent that
||| runs out of budget reports the budget, not the work it wanted to do.
public export
clampNat : Nat -> Nat -> Nat
clampNat x m = if x <= m then x else m

export
clampUnderBudget : clampNat 5 10 = 5
clampUnderBudget = Refl

export
clampOverBudget : clampNat 12 10 = 10
clampOverBudget = Refl

export
clampExactlyBudget : clampNat 10 10 = 10
clampExactlyBudget = Refl

--------------------------------------------------------------------------------
-- The v0 decision rule — the whole of it
--------------------------------------------------------------------------------

||| Decide what this agent should do.
|||
||| Thresholds are written as literals rather than named constants. The reason
||| first recorded here — "Idris2 does not unfold a top-level constant in a proof
||| position" — was MEASURED WRONG on 2026-09-20. Qualified, a constant reduces
||| normally: `NonZero Abi.Types.memoryTtl` proves by `SIsNonZero`. The real trap
||| is that a BARE lowercase name in a TYPE is implicitly bound as a fresh
||| implicit argument, silently shadowing the global, so the theorem becomes a
||| claim about an unknown variable that can never reduce — which is what the
||| misdiagnosis was seeing, and why it looked like an evaluator limit.
|||
||| `Abi.Memory` is the pattern to copy: named constants, written with their full
||| path in theorem types, proved by `Refl`. The literals here are kept because the
||| theorems below were written against them, not because the names are
||| unprovable. Names in the comments, numbers in the code, theorems pinning
||| them — that part was always right. See docs/developer/IDRIS2-NOTES.adoc.
|||
|||   16384  = 0.25 in Q16.16   — "wounded"
|||   65536  = 1.00             — attack range
|||   131072 = 2.00             — flee range
public export
decide : Scenario -> (Action, Nat)
decide s =
  if ammo s == 0
     then (ActReload, 0)
     else if contactCount s == 0
             then (ActAdvance, 0)
             else if health s < 16384 && nearestDist s < 131072
                     then (ActFlee, nearestId s)
                     else if nearestDist s <= 65536
                             then (ActAttack, nearestId s)
                             else (ActAdvance, nearestId s)

-- The rule's behaviour in each branch, proved rather than described.

export
reloadsWhenOutOfAmmo : decide (MkScenario 65536 0 3 1000 7) = (ActReload, 0)
reloadsWhenOutOfAmmo = Refl

export
advancesWhenAlone : decide (MkScenario 65536 65536 0 0 0) = (ActAdvance, 0)
advancesWhenAlone = Refl

export
fleesWhenWoundedAndOutgunned : decide (MkScenario 1000 65536 1 1000 7) = (ActFlee, 7)
fleesWhenWoundedAndOutgunned = Refl

export
attacksInRange : decide (MkScenario 65536 65536 1 32768 7) = (ActAttack, 7)
attacksInRange = Refl

export
holdsGroundWoundedButSafe : decide (MkScenario 1000 65536 1 1048576 7) = (ActAdvance, 7)
holdsGroundWoundedButSafe = Refl

export
advancesWhenContactsOutOfRange : decide (MkScenario 65536 65536 2 262144 9) = (ActAdvance, 9)
advancesWhenContactsOutOfRange = Refl

||| Ammo outranks self-preservation: an agent with no ammo reloads even while
||| wounded and under fire. Ordering of the branches is part of the policy, so it
||| is pinned by a theorem, and reordering the `if`s fails this proof.
export
reloadOutranksFlee : decide (MkScenario 1000 0 1 10 7) = (ActReload, 0)
reloadOutranksFlee = Refl

--------------------------------------------------------------------------------
-- The tick
--------------------------------------------------------------------------------

||| One tick. Pure: the type admits no IO, so the kernel cannot observe the wall
||| clock, the filesystem, or the host (ADR-0004, ADR-0006).
|||
||| `budget` is the host-declared per-agent allowance; the work model is crude on
||| purpose at v0 (four fixed units plus one per contact) and is expected to be
||| replaced when the decision layer grows.
public export
tickModel : (budget : Nat) -> Scenario -> AgentState -> (AgentState, Intent)
tickModel budget s a =
  let (act, tgt) = decide s
      wanted = contactCount s + 4
      used = clampNat wanted budget
      degraded = wanted > budget
  in ( MkAgentState (rngState a) (tickLast a) act tgt used (degradedTicks a)
     , MkIntent act tgt used degraded )

||| The tick is deterministic: same inputs, same outputs, as an equation.
export
tickDeterministic : tickModel 32 (MkScenario 65536 65536 2 32768 7)
                              (MkAgentState 1 0 ActIdle 0 0 0)
                  = tickModel 32 (MkScenario 65536 65536 2 32768 7)
                              (MkAgentState 1 0 ActIdle 0 0 0)
tickDeterministic = Refl

||| The budget guard honours its budget in the case the tests exercise: 40 units
||| of wanted work against a budget of 32 reports 32, and flags degradation.
export
tickIsBudgeted : intentBudgetUsed (snd (tickModel 32 (MkScenario 65536 65536 36 32768 7)
                                                      (MkAgentState 1 0 ActIdle 0 0 0))) = 32
tickIsBudgeted = Refl

export
tickFlagsDegradation : intentDegraded (snd (tickModel 32 (MkScenario 65536 65536 36 32768 7)
                                                     (MkAgentState 1 0 ActIdle 0 0 0))) = True
tickFlagsDegradation = Refl

||| ...and does NOT flag degradation when the work fits.
export
tickFlagsNoDegradationWhenIdle : intentDegraded (snd (tickModel 32 (MkScenario 65536 65536 0 0 0)
                                                                (MkAgentState 1 0 ActIdle 0 0 0))) = False
tickFlagsNoDegradationWhenIdle = Refl

||| The state the tick hands back records the action it chose, so a caller that
||| only keeps the state (the ABI's actual shape) still has the agent's context.
export
tickRecordsDecision : cachedAction (fst (tickModel 32 (MkScenario 65536 65536 1 32768 7)
                                                     (MkAgentState 1 0 ActIdle 0 0 0))) = ActAttack
tickRecordsDecision = Refl

--------------------------------------------------------------------------------
-- The ABI entry points, as types
--------------------------------------------------------------------------------
-- These mirror the declarations the generated header carries. They are written
-- as pure descriptions of shape and effect; the exported implementations live in
-- Zig (src/interface/ffi/), which asserts the generated layout at comptime.

||| What the host declares at init.
public export
record InitRequest where
  constructor MkInitRequest
  declaredVersion : Version
  declaredCapabilities : Nat
  declaredFingerprint : Nat
  maxAgents : Nat
  budget : Nat

||| What the kernel answers.
public export
record InitResponse where
  constructor MkInitResponse
  handshake : Handshake
  grantedCapabilities : Nat
  agentStructSize : Nat
  budget : Nat

||| The init handshake, as a total pure function: every request has an answer,
||| and a mismatch is ANSWERED rather than thrown (ADR-0005 §3).
public export
initModel : InitRequest -> InitResponse
initModel r =
  let hs = negotiate abiVersion (declaredVersion r)
  in MkInitResponse hs (declaredCapabilities r) 48 (budget r)

||| A host declaring v1 is accepted.
export
initAcceptsOwnVersion : handshake (initModel (MkInitRequest (MkVersion 1 0 0) 0 0 64 32)) = Compatible
initAcceptsOwnVersion = Refl

||| A host declaring a different major version is refused, with the reason.
export
initRefusesMajorMismatch : handshake (initModel (MkInitRequest (MkVersion 3 0 0) 0 0 64 32)) = HostTooNew
initRefusesMajorMismatch = Refl

||| The agent state size the kernel reports is the one `Abi.Layout` proved, so a
||| too-small host buffer is caught at init rather than corrupting memory later.
export
initReportsProvenAgentSize : agentStructSize (initModel (MkInitRequest (MkVersion 1 0 0) 0 0 64 32)) = 48
initReportsProvenAgentSize = Refl
