-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
||| Evil Weevil ABI — the utility graph (Phase 2).
|||
||| v0's rule is an if/else chain: the ORDER of the branches IS the policy. This
||| module writes the same policy down as SCORES plus a maximum, because a chain of
||| branches cannot be extended without arguing about where the new branch goes,
||| and a graph can: adding a behaviour means adding a score.
|||
||| == Why this changes nothing — and why that is the whole point
|||
||| The scores below are the priorities the kernel was ALREADY reporting in
||| `ee_intent.priority` (65536, 58982, 52428, 26214, and the 32768 Phase 2 added
||| for INVESTIGATE). So replacing the chain with a maximum over these scores is a
||| refactor, not a policy change: every branch is reached for the same inputs, and
||| the three pinned digests in the null hosts do not move. That is the evidence —
||| a refactor that claims to preserve behaviour and cannot point at a number that
||| would have moved is a claim about a program nobody runs.
|||
||| Where the scores ARE new, they are recorded here as the thing they already
||| meant: `EE_ACTION_RELOAD` outranks flight, flight outranks attack, attack
||| outranks investigation, investigation outranks a walk.
|||
||| == Not on the wire
|||
||| The scores are deliberately NOT emitted into `ee.h`. A host may read
||| `ee_intent.priority` to compare two intents, but policy WEIGHTS are not ABI: a
||| host that hard-codes 58982 as "flee" would break the day the graph is tuned,
||| and tuning the graph is exactly what the graph exists to make easy. The wire
||| carries actions, targets and flags; the numbers that produced them are ours.

module Abi.Utility

import Abi.Types
import Abi.Foreign
import Abi.Memory
import Data.Nat

%default total

--------------------------------------------------------------------------------
-- The scores — the policy, written where it can be read
--------------------------------------------------------------------------------

public export
scoreReload : Nat
scoreReload = 65536

public export
scoreFlee : Nat
scoreFlee = 58982

public export
scoreAttack : Nat
scoreAttack = 52428

public export
scoreInvestigate : Nat
scoreInvestigate = 32768

public export
scoreAdvance : Nat
scoreAdvance = 26214

public export
scoreHold : Nat
scoreHold = 0

--------------------------------------------------------------------------------
-- What the graph is asked about a moment
--------------------------------------------------------------------------------

||| The inputs the scores read. Deliberately small: a score that needs something
||| else is a score that has not been thought through yet.
|||
||| `sitDistance` is only meaningful when a contact is visible; `sitContact`
||| guards it rather than a sentinel, because a distance of zero is a contact
||| standing on top of the agent, not an absent one.
public export
record Situation where
  constructor MkSituation
  sitContact      : Bool
  sitDistance     : Nat
  sitWounded      : Bool
  sitAmmoZero     : Bool
  sitMemoryFresh  : Bool

||| The candidates, in the order ties are broken. The order is v0's branch order
||| because that is what makes this a refactor: a tie that cannot be decided by
||| score is decided the way the chain decided it.
|||
||| Six of the ABI's nine actions are candidates. IDLE, TAKE_COVER and REGROUP are
||| not yet reachable — they score zero everywhere, and a score of zero can never
||| win against a positive one — because nothing in the model would justify them
||| yet. They join this list the day a score for them exists.
public export
allCandidates : List Action
allCandidates = [ActReload, ActFlee, ActAttack, ActInvestigate, ActAdvance, ActHold]

||| The candidates for a MOMENT. Usually all of them; the exception is the moment
||| this slice exists to get right.
|||
||| v0 decided with a chain and then ran its memory branch on the way out: nothing
||| visible and a memory still fresh REPLACED whatever the chain had chosen. The
||| two rules disagree at exactly one kind of moment — nothing visible, a fresh
||| lead, and no ammo, where the chain says reload and the memory branch says
||| investigate — and the chain did not win, because the memory branch ran last.
|||
||| Measured, not inferred: fixture 1 drops contacts every fifth tick (`t % 5`) and
||| empties the magazine every seventeenth, so the collision is `t = 85, 170, ...`
||| and the pinned digest of the 10,000-tick trace is what moved when this module
||| first let reload win there (`14165495496352896129` -> `57428431722396483`).
||| Investigation is therefore written as the ONLY candidate in that moment rather
||| than as a competitor that outscores reload, because the agent is not weighing
||| two options: with nothing to look at, the lead is the task. Raising the score
||| instead would have changed the priority the intent REPORTS, which is ABI, and
||| a refactor that changes the wire to make its own ordering work is not one.
|||
||| Whether an ammo-less agent should investigate at all is a real policy question
||| and NOT a settled one: it is recorded as open in ADR-0010, and answering it
||| moves the digest — which is how you can tell it is a policy change and not a
||| refactor. Until then the graph reproduces v0.
public export
candidates : Situation -> List Action
candidates s = if sitContact s then allCandidates
                 else if sitMemoryFresh s then [ActInvestigate]
                 else allCandidates

||| One action's score in one situation.
|||
||| Every comparison is against a LITERAL threshold, for the reason `Abi.Foreign`
||| records: the thresholds are the policy, and the theorems below pin them.
public export
scoreOf : Action -> Situation -> Nat
scoreOf ActReload s      = if sitAmmoZero s then scoreReload else 0
scoreOf ActFlee s        = if sitContact s && sitWounded s && sitDistance s < 131072
                              then scoreFlee else 0
scoreOf ActAttack s      = if sitContact s && sitDistance s <= 65536
                              then scoreAttack else 0
scoreOf ActInvestigate s = if sitContact s then 0
                              else if sitMemoryFresh s then scoreInvestigate else 0
scoreOf ActAdvance s     = if sitContact s then scoreAdvance
                              else if sitMemoryFresh s then 0 else scoreAdvance
scoreOf ActHold s        = scoreHold
-- The remaining three actions are NOT candidates yet. Scored zero explicitly
-- rather than omitted, because this function pattern-matches on every constructor
-- on purpose: an action added to the ABI silently scoring zero would be a policy
-- decision made by a compiler warning, and this module does not make those.
scoreOf ActIdle s        = 0
scoreOf ActTakeCover s   = 0
scoreOf ActRegroup s     = 0

||| The maximum, taking the EARLIEST candidate among equals: structural on the
||| list, so it reduces for a literal situation and the theorems below are proofs
||| rather than statements of intent.
public export
best : Nat -> Action -> List Action -> Situation -> (Action, Nat)
best sc act []        s = (act, sc)
best sc act (a :: as) s =
  let sc' = scoreOf a s in
  if sc' > sc then best sc' a as s else best sc act as s

||| What the agent does.
public export
choose : Situation -> Action
choose s = fst (best 0 ActHold (candidates s) s)

--------------------------------------------------------------------------------
-- The scores are strictly ordered, so the graph has no accidental ties
--------------------------------------------------------------------------------

export
holdIsLowest : (Abi.Utility.scoreHold < Abi.Utility.scoreAdvance) = True
holdIsLowest = Refl

export
advanceBelowInvestigate : (Abi.Utility.scoreAdvance < Abi.Utility.scoreInvestigate) = True
advanceBelowInvestigate = Refl

export
investigateBelowAttack : (Abi.Utility.scoreInvestigate < Abi.Utility.scoreAttack) = True
investigateBelowAttack = Refl

export
attackBelowFlee : (Abi.Utility.scoreAttack < Abi.Utility.scoreFlee) = True
attackBelowFlee = Refl

export
fleeBelowReload : (Abi.Utility.scoreFlee < Abi.Utility.scoreReload) = True
fleeBelowReload = Refl

--------------------------------------------------------------------------------
-- The graph reproduces v0, branch by branch
--------------------------------------------------------------------------------
-- Each theorem gives BOTH rules the same moment and states that they name the same
-- action. `Refl` is the whole proof, because both sides reduce — which is what makes
-- this a check on the code rather than a description of it.

||| First component of a triple. `decideWithMemory` returns (action, target, flag),
||| and an action is what these theorems are about.
fstOf3 : (a, b, c) -> a
fstOf3 (x, _, _) = x

export
graphAgreesWithRuleOnReload :
  choose (MkSituation True 1000 True True False)
  = fst (decide (MkScenario 32768 0 3 1000 7))
graphAgreesWithRuleOnReload = Refl

export
graphAgreesWithRuleOnFlee :
  choose (MkSituation True 40000 True False False)
  = fst (decide (MkScenario 8192 65536 1 40000 9))
graphAgreesWithRuleOnFlee = Refl

export
graphAgreesWithRuleOnAttack :
  choose (MkSituation True 32768 False False False)
  = fst (decide (MkScenario 65536 65536 1 32768 7))
graphAgreesWithRuleOnAttack = Refl

export
graphAgreesWithRuleOnClosingAdvance :
  choose (MkSituation True 196608 False False False)
  = fst (decide (MkScenario 65536 65536 1 196608 7))
graphAgreesWithRuleOnClosingAdvance = Refl

export
graphAgreesWithRuleOnEmptyAdvance :
  choose (MkSituation False 0 False False False)
  = fst (decide (MkScenario 65536 65536 0 0 0))
graphAgreesWithRuleOnEmptyAdvance = Refl

||| The one branch v0 did not have: nothing visible, but a memory still fresh. The
||| graph must agree with `Abi.Memory`'s rule, not with v0's.
export
graphAgreesWithMemoryRuleOnInvestigate :
  choose (MkSituation False 0 False False True)
  = fstOf3 (decideWithMemory
              (MkSeeing 65536 65536 0 0 0 0 0
                (remember 42 16384 8192 Abi.Memory.emptyMemory)))
graphAgreesWithMemoryRuleOnInvestigate = Refl

--------------------------------------------------------------------------------
-- The ordering the graph has to keep
--------------------------------------------------------------------------------

||| Ammo beats what a VISIBLE fight offers: fleeing a wound, and the memory of one.
||| (A sighting is not overridden by memory — memory is consulted only when there is
||| nothing to see — so this moment is handled by the scores.)
export
reloadBeatsFleeAndMemory :
  choose (MkSituation True 40000 True True True) = ActReload
reloadBeatsFleeAndMemory = Refl

||| The two sides of the collision at `t = 85`, pinned as a pair so that neither can
||| drift without the other: no lead to follow and an empty magazine reloads, and an
||| empty magazine with a lead still follows the lead — v0's order, not v0's comment.
export
noLeadOutOfAmmoReloads :
  choose (MkSituation False 0 False True False) = ActReload
noLeadOutOfAmmoReloads = Refl

export
blindWithLeadInvestigatesEvenOutOfAmmo :
  choose (MkSituation False 0 False True True) = ActInvestigate
blindWithLeadInvestigatesEvenOutOfAmmo = Refl

||| The triangle, closed at the contentious moment: the graph, this module's
||| re-statement of `Abi.Memory`'s rule, and the kernel whose digests are pinned all
||| agree that a blind agent with a lead follows the lead. Three surfaces, one
||| number — the digest — and the reason the collision was found at all.
export
graphAgreesWithMemoryRuleWhenOutOfAmmo :
  choose (MkSituation False 0 False True True)
  = fstOf3 (decideWithMemory
              (MkSeeing 65536 0 0 0 0 0 0
                (remember 42 16384 8192 Abi.Memory.emptyMemory)))
graphAgreesWithMemoryRuleWhenOutOfAmmo = Refl

||| A visible contact beats a memory: somebody standing in front of you outranks
||| wherever somebody used to be.
export
sightBeatsMemoryInTheGraph :
  choose (MkSituation True 196608 False False True) = ActAdvance
sightBeatsMemoryInTheGraph = Refl

||| The memory is the only thing separating investigate from a walk.
export
memoryDecidesBetweenInvestigateAndAdvance :
  (choose (MkSituation False 0 False False True),
   choose (MkSituation False 0 False False False))
  = (ActInvestigate, ActAdvance)
memoryDecidesBetweenInvestigateAndAdvance = Refl

||| And the score the kernel reports for an investigation is this one, pinned.
export
investigateScoreIsWhatItSays : Abi.Utility.scoreInvestigate = 32768
investigateScoreIsWhatItSays = Refl
