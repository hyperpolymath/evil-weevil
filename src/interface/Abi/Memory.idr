-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
||| Evil Weevil ABI — perception memory (Phase 2, first slice).
|||
||| v0's rule was amnesiac: an agent that lost sight of a contact forgot it
||| instantly and went back to advancing. This module is the specification of the
||| memory that fixes that. The tie between this rule and the Zig kernel is the
||| same as for `Abi.Foreign`: the kernel implements what is written here, and a
||| 10,000-tick digest pinned in CI makes a divergence loud.
|||
||| == STATUS: specified, proved, and implemented
|||
||| `src/core/kernel.zig` implements this rule (ADR-0009). Wiring it MOVED the v0
||| 10,000-tick digest, because that fixture has zero-contact ticks
||| (`contact_count = tick % 5`) and the new branch fires inside it — the first
||| draft of ADR-0009 predicted otherwise, and the gate corrected it within a
||| minute. The old number survives as a STRONGER assertion than the pin it used to
||| be: clear `EE_AGENT_FLAG_MEMORY_VALID` after every tick and the kernel
||| reproduces v0 exactly, which both hosts now check. Memory itself is pinned by a
||| third number, from a scenario built to reach forgetting ("the one that got
||| away": 30 ticks seen, 70 unseen, per 100).
|||
||| == What is remembered
|||
||| A DIRECTION, not a position. Contacts arrive with a bearing (two Q16.16
||| components) and a distance; a remembered world POSITION would drift as the
||| agent moves, and this phase has no fixed-point vector arithmetic to correct
||| it. What an agent needs in order to investigate is where to walk, and the last
||| known bearing is exactly that. This is a recorded choice, not a permanent one:
||| when memory stores positions (steering work, later in Phase 2), this module
||| changes and so does the digest.
|||
||| == What is proved, and what is not
|||
||| Proved, below: the TTL is positive, a sighting is immediately fresh and resets
||| the age, a memory is still fresh one tick short of the TTL and gone at it,
||| forgetting clears the payload rather than merely marking it old, an empty
||| memory is never fresh and is not made fresh by ageing, and the rule's
||| behaviour in each memory branch.
|||
||| NOT proved, deliberately: the general theorem "ageing is monotone" for all
||| memories. `ageMemory` branches on `a + 1 < memoryTtl`; `<` on Nat is decided
||| by recursion, so the general statement needs order lemmas this module does not
||| depend on. The theorems are therefore stated over the TTL and the instances
||| the kernel actually uses — the same convention `Abi.Foreign` records for the
||| budget guard. Prove what reduces; pin the rest with a digest; say which is
||| which.
|||
||| == A note on names in types (corrects an earlier belief in this repo)
|||
||| `memoryTtl` and `intentFlagFromMemory` are referred to by their FULL paths in
||| the theorem types below, and a bare lowercase name in a type is a trap: Idris2
||| implicitly binds it as a fresh implicit argument, silently shadowing the
||| global, so the theorem becomes a statement about an unknown variable and can
||| never reduce. That is what "top-level constants don't unfold" looked like from
||| the outside — it was not the evaluator, it was the binder. Qualified, these
||| constants reduce normally, which is why the theorems here can be `Refl` and
||| `Abi.Foreign`'s header comment saying otherwise has been corrected.
|||
||| == Where this lives in the wire format (decided 2026-09-20, ADR-0009)
|||
||| v0's `ee_agent` was built with room for this: `memory_x`, `memory_y` (both Fx)
||| and `memory_age` (U32) sat in it unused, and `flags` had no defined bits. Phase
||| 2 therefore needs NO layout change — the ABI stays 1.0 and the layout checksum
||| does not move — because defining a previously-undefined bit and using
||| previously-ignored fields is additive. The mapping is:
|||
|||   memValid      <-> ee_agent.flags bit 0 (EE_AGENT_FLAG_MEMORY_VALID)
|||   memId         <-> ee_agent.cached_target
|||   memBearingCos <-> ee_agent.memory_x
|||   memBearingSin <-> ee_agent.memory_y
|||   memAge        <-> ee_agent.memory_age
|||
||| `memId` rides on `cached_target` because that field already holds "the id this
||| agent is pursuing", written from the last decision — and on the last tick a
||| contact was visible, that IS the remembered contact. Growing the struct was the
||| alternative, and was rejected: a breaking layout change for state the format
||| already had room for. Hiding memory inside the kernel was rejected outright:
||| hidden state in a deterministic kernel is the property this architecture exists
||| to avoid.

module Abi.Memory

import Abi.Types
import Data.Nat

%default total

--------------------------------------------------------------------------------
-- The memory itself
--------------------------------------------------------------------------------

||| What the agent carries about a contact it can no longer see.
|||
||| `memValid` is not redundant with `memAge`: a forgotten memory must read as
||| "nothing known" even though its age field still holds a number, and the flag
||| is what makes forgetting observable rather than implied.
public export
record Memory where
  constructor MkMemory
  memValid      : Bool
  memId         : Nat    -- the contact's id, so the intent can name it
  memBearingCos : Nat    -- last known direction, Q16.16
  memBearingSin : Nat
  memAge        : Nat    -- ticks since the sighting

||| A memory that has never been written.
public export
emptyMemory : Memory
emptyMemory = MkMemory False 0 0 0 0

--------------------------------------------------------------------------------
-- Reading and writing it
--------------------------------------------------------------------------------

||| Is there something to act on?
||| `memoryTtl` is `Abi.Types.memoryTtl`; in a term position the bare name
||| resolves to the global, and (unlike a bare name in a TYPE) it is not bound
||| implicitly.
public export
memFresh : Memory -> Bool
memFresh m = memValid m && memAge m < memoryTtl

||| Record a sighting. The age goes back to zero and the direction is
||| overwritten: the most recent look is the best one.
public export
remember : (id, cos, sin : Nat) -> Memory -> Memory
remember id c s m = MkMemory True id c s 0

||| A tick in which nothing was seen: the memory ages, and at the TTL it is
||| forgotten — payload cleared, not merely marked old. A forgotten memory that
||| still held an id would be one `memValid` bug away from steering an agent at a
||| contact that is two minutes stale.
|||
||| Forgetting means forgetting: both branches return `emptyMemory`, so a
||| forgotten memory cannot still carry an id that a later bug could act on. (An
||| earlier draft inlined the record literal here on the belief that a nullary
||| constant would not reduce — it does, when qualified in a type; see the note on
||| names in the module header.)
public export
ageMemory : Memory -> Memory
ageMemory m =
  case m of
    MkMemory False _ _ _ _ => emptyMemory
    MkMemory True i c s a  =>
      if a + 1 < memoryTtl
         then MkMemory True i c s (a + 1)
         else emptyMemory

||| Age a memory `n` ticks without sight. Structural on `n`, so it REDUCES for a
||| literal `n` — which is what makes the theorems below proofs rather than
||| wishes.
public export
ageN : Nat -> Memory -> Memory
ageN Z     m = m
ageN (S k) m = ageN k (ageMemory m)

--------------------------------------------------------------------------------
-- The numbers, pinned
--------------------------------------------------------------------------------

||| The TTL is not zero. A witness rather than a comment, because every freshness
||| claim below is vacuous if it is.
export
ttlIsPositive : NonZero Abi.Types.memoryTtl
ttlIsPositive = SIsNonZero

||| The TTL is 36 ticks. Stated separately from `ttlIsPositive` so that changing
||| the constant fails to compile here rather than quietly changing behaviour:
||| 0.6 s at 60 Hz, long enough to pursue somebody who stepped behind a pillar,
||| short enough that nobody walks to where a player stood ten seconds ago.
export
ttlIsThirtySix : Abi.Types.memoryTtl = 36
ttlIsThirtySix = Refl

||| The memory flag is bit 3, and it is a bit VALUE (8), not an index (3): the
||| kernel ors flags together, so this is the number the host will see.
export
memoryFlagIsEight : Abi.Types.intentFlagFromMemory = 8
memoryFlagIsEight = Refl

--------------------------------------------------------------------------------
-- Theorems about the memory
--------------------------------------------------------------------------------

||| A sighting is immediately actionable, whatever the memory held before —
||| including a memory that had been forgotten.
export
rememberIsFresh : (id, c, s : Nat) -> (m : Memory) ->
                  memFresh (remember id c s m) = True
rememberIsFresh id c s m = Refl

||| ...and its age is zero, so "the first tick of a pursuit" is a fact about the
||| data rather than a comment in the kernel.
export
rememberResetsAge : (id, c, s : Nat) -> (m : Memory) ->
                    memAge (remember id c s m) = 0
rememberResetsAge id c s m = Refl

||| Still actionable one tick short of the TTL. Written with `pred` rather than
||| `memoryTtl - 1` because `(-)` on Nat in this base is the `Neg` interface
||| (Integer/Int/Double), and there is no `Neg Nat`: the subtraction is `pred`.
export
freshJustBeforeTtl :
  memFresh (ageN (pred Abi.Types.memoryTtl) (remember 7 16384 8192 Abi.Memory.emptyMemory)) = True
freshJustBeforeTtl = Refl

||| ...and gone at it. The boundary is the TTL, not the TTL plus one: an agent
||| that forgets a contact on the tick it expires is forgetful; one that keeps it
||| a tick longer is a rule nobody can state from the outside.
export
staleAtTtl :
  memFresh (ageN Abi.Types.memoryTtl (remember 7 16384 8192 Abi.Memory.emptyMemory)) = False
staleAtTtl = Refl

||| Forgetting clears the payload: no valid flag, no id, no direction, no age.
export
forgottenHoldsNothing :
  ageN Abi.Types.memoryTtl (remember 7 16384 8192 Abi.Memory.emptyMemory)
  = MkMemory False 0 0 0 0
forgottenHoldsNothing = Refl

||| An empty memory is never fresh. `memValid False && ...` is not false by
||| convention — the `&&` settles it.
export
emptyIsNotFresh : memFresh Abi.Memory.emptyMemory = False
emptyIsNotFresh = Refl

||| Ageing a default memory leaves it defaulted: an agent that has seen nothing is
||| not made to believe something by the passage of time. By induction on `n`.
export
ageingEmptyKeepsEmpty : (n : Nat) -> ageN n Abi.Memory.emptyMemory = Abi.Memory.emptyMemory
ageingEmptyKeepsEmpty Z     = Refl
ageingEmptyKeepsEmpty (S k) = ageingEmptyKeepsEmpty k

--------------------------------------------------------------------------------
-- The rule, with memory — the Phase 2 addition to Abi.Foreign's five branches
--------------------------------------------------------------------------------

||| v0's `Scenario`, plus what the agent remembers. Kept alongside rather than
||| inside `Abi.Foreign` so that the v0 rule stays readable as what it was.
public export
record Seeing where
  constructor MkSeeing
  seenHealth       : Nat
  seenAmmo         : Nat
  seenContacts     : Nat
  seenNearestDist  : Nat
  seenNearestId    : Nat
  seenBearingCos   : Nat
  seenBearingSin   : Nat
  seenMemory       : Memory

||| The v0 rule, extended at exactly one point: with nothing visible and a memory
||| still fresh, the agent investigates instead of advancing.
|||
||| Branch ORDER is the policy, not an accident — and the order this rule has is
||| the order the SHIPPED kernel has, which ADR-0010 established by measurement
||| after this module first got it wrong. With something in sight the old rule
||| applies unchanged, ammo first: flee before attack before advance, and no ammo
||| outranks all of it (an agent with nothing to shoot at reloads). With NOTHING in
||| sight a fresh lead outranks the magazine, because that is what `kernel.zig` did
||| when this rule was written and the pinned digest says so: the kernel decided
||| with the chain and then ran its memory branch on the way out, so the memory
||| REPLACED the decision. The two orders disagree at exactly one moment — nothing
||| visible, a fresh lead, no ammo — and at `t = 85, 170, ...` of the 10,000-tick
||| trace the disagreement moved the digest from 14165495496352896129 to
||| 57428431722396483 while this module was still claiming otherwise.
|||
||| Which order is DESIRABLE is a policy question this slice is not allowed to
||| answer (ADR-0010 decision 6 records it as open): a refactor may not change
||| behaviour, and a specification that disagrees with the code the digest pins is
||| the specification that is wrong. The returned triple is (action, target id,
||| intent flags); the flag is the literal 8 with
||| `Abi.Types.intentFlagFromMemory` as its name, because the theorems below pin
||| the number.
public export
decideWithMemory : Seeing -> (Action, Nat, Nat)
decideWithMemory s =
  if seenContacts s /= 0
     then if seenAmmo s == 0
             then (ActReload, 0, 0)
             else if seenHealth s < 16384 && seenNearestDist s < 131072
                     then (ActFlee, seenNearestId s, 0)
                     else if seenNearestDist s <= 65536
                             then (ActAttack, seenNearestId s, 0)
                             else (ActAdvance, seenNearestId s, 0)
     else if memFresh (seenMemory s)
             then (ActInvestigate, memId (seenMemory s), 8)
             else if seenAmmo s == 0
                     then (ActReload, 0, 0)
                     else (ActAdvance, 0, 0)

||| Nothing in sight, but a fresh memory: investigate what was remembered, and SAY
||| so. The flag is the whole point — without it a host cannot tell "walking
||| towards an enemy" from "walking towards where an enemy was".
export
investigatesWithFreshMemory :
  decideWithMemory (MkSeeing 65536 65536 0 0 0 0 0 (remember 42 16384 8192 Abi.Memory.emptyMemory))
  = (ActInvestigate, 42, 8)
investigatesWithFreshMemory = Refl

||| Nothing in sight and nothing remembered: advance, with no flag claiming memory
||| was involved.
export
advancesWithoutMemory :
  decideWithMemory (MkSeeing 65536 65536 0 0 0 0 0 Abi.Memory.emptyMemory)
  = (ActAdvance, 0, 0)
advancesWithoutMemory = Refl

||| Memory does not override the ammo rule WHERE THERE IS SOMETHING TO SHOOT AT.
||| This was `reloadOutranksMemory` and it asserted the opposite of what the kernel
||| does, because it was the only theorem here that put no ammo and a fresh memory in
||| the same moment — and that moment is precisely where the two orders diverge. See
||| the module header and ADR-0010: the digest decided, and the digest follows the
||| kernel.
export
sightingKeepsReloadUrgent :
  decideWithMemory (MkSeeing 65536 0 1 40000 9 0 0 (remember 42 16384 8192 Abi.Memory.emptyMemory))
  = (ActReload, 0, 0)
sightingKeepsReloadUrgent = Refl

||| The other side of that moment, pinned so that neither half of the collision can
||| move alone: blind, out of ammo, and still following the lead — `t = 85`, as the
||| kernel does it and as the digest asserts it.
export
blindWithLeadInvestigatesEvenOutOfAmmo :
  decideWithMemory (MkSeeing 65536 0 0 0 0 0 0 (remember 42 16384 8192 Abi.Memory.emptyMemory))
  = (ActInvestigate, 42, 8)
blindWithLeadInvestigatesEvenOutOfAmmo = Refl

||| And with nothing remembered, the ammo rule is back in charge: the magazine is
||| the only thing left to reach for.
export
noLeadOutOfAmmoReloads :
  decideWithMemory (MkSeeing 65536 0 0 0 0 0 0 Abi.Memory.emptyMemory)
  = (ActReload, 0, 0)
noLeadOutOfAmmoReloads = Refl

||| A visible contact beats a memory every time, so an agent never investigates
||| where somebody *was* while somebody is standing in front of it.
export
sightOutranksMemory :
  decideWithMemory (MkSeeing 65536 65536 1 32768 9 0 0 (remember 42 16384 8192 Abi.Memory.emptyMemory))
  = (ActAttack, 9, 0)
sightOutranksMemory = Refl

||| And a stale memory is not investigated either: the rule falls through to v0's
||| advance rather than pursuing a ghost.
export
staleMemoryIsNotFollowed :
  decideWithMemory (MkSeeing 65536 65536 0 0 0 0 0
                      (ageN Abi.Types.memoryTtl (remember 42 16384 8192 Abi.Memory.emptyMemory)))
  = (ActAdvance, 0, 0)
staleMemoryIsNotFollowed = Refl
