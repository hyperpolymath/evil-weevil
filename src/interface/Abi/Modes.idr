-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
||| Evil Weevil ABI — modes and commitment (Phase 2, slice 3; the VSM S2 layer).
|||
||| The utility graph (ADR-0010) decides well and commits to nothing. It is memoryless
||| per tick: two ticks whose scores differ by one unit produce two different
||| behaviours, and an agent that flips between attacking and fleeing every tick is
||| worse to play against than one that does either badly. That flapping is an
||| ENGINEERING defect before it is a taste question: a behaviour that changes every
||| tick cannot be observed, tuned, or authored against.
|||
||| This module adds the layer above the graph: a MODE the agent is in, and a MARGIN a
||| challenger must clear before the mode changes. Modes select WHICH behaviour is in
||| play; the graph still decides the tactic within it. That separation is the design —
||| see ADR-0012, which maps the layers onto Beer's VSM.
|||
||| == The margin is a Schmitt trigger, not a counter
|||
||| Hysteresis usually costs state: "stay in this mode for N ticks" needs a countdown.
||| This does not. The incumbent mode's score is boosted by `stickiness`, so a
||| challenger must beat the incumbent by MORE than the margin to take over. Enter and
||| exit thresholds differ, oscillation needs a large input swing, and the only state
||| is the mode itself — three bits `ee_agent.flags` was already carrying undefined.
||| No layout change, no counter field, ABI stays 1.0.
|||
||| The margin can only hold a mode that still APPLIES. A mode whose precondition has
||| failed scores zero, so stickiness cannot resurrect it: an engaged agent whose
||| contact leaves attack range stops being engaged, margin or no margin. Commitment
||| must not become blindness.
|||
||| == What this changes, and the price
|||
||| This is a POLICY change and it moves the pinned digests, deliberately, exactly as
||| ADR-0006 requires. Two consequences are recorded rather than discovered later:
|||
||| * An engaged, wounded agent at close range no longer breaks off on the strength of
|||   the wound alone: flee (58982) does not out-score attack plus the margin (52428 +
|||   8192). It disengages when the contact leaves attack range or is lost.
||| * The memory-opted-out digest was v0's exact number, and was the evidence that
|||   memory was additive (ADR-0009 decision 5). It cannot remain v0's number once
|||   modes exist: it is now "modes with memory opted out". ADR-0012 records that
|||   retirement and the new pin, because a compat number that quietly starts measuring
|||   something else is worse than no compat number.

module Abi.Modes

import Abi.Types
import Abi.Utility
import Data.So

%default total

--------------------------------------------------------------------------------
-- The modes
--------------------------------------------------------------------------------

||| The behaviours an agent can be committed to. Five, because these are the five the
||| graph can already produce; a mode with no tactic behind it would be a state an
||| agent can enter and do nothing in.
|||
||| `ModeAdvance` is the neutral mode and the zero code, so a zeroed `ee_agent` — what
||| a host gets from `memset` — starts where v0 would have behaved.
public export
data Mode = ModeAdvance | ModeEngage | ModeEvade | ModeReload | ModeInvestigate

||| Mode equality, written out rather than derived: keeping the decision procedure
||| visible means a wrong clause here would be a wrong mode in the kernel.
public export
eqMode : Mode -> Mode -> Bool
eqMode ModeAdvance ModeAdvance = True
eqMode ModeEngage ModeEngage = True
eqMode ModeEvade ModeEvade = True
eqMode ModeReload ModeReload = True
eqMode ModeInvestigate ModeInvestigate = True
eqMode _ _ = False

--------------------------------------------------------------------------------
-- The wire encoding: three bits of ee_agent.flags, bits 1..3
--------------------------------------------------------------------------------

||| Where the mode lives in `ee_agent.flags`. Bit 0 is `EE_AGENT_FLAG_MEMORY_VALID`
||| (ADR-0009); the mode takes the next three bits, which the freeze left undefined.
public export
modeShift : Nat
modeShift = 1

public export
modeMask : Nat
modeMask = 14

||| The code for each mode. Zero for the neutral mode, so zeroed agent memory means
||| "in no particular mode" rather than accidentally engaging.
public export
modeCode : Mode -> Nat
modeCode ModeAdvance = 0
modeCode ModeEngage = 1
modeCode ModeEvade = 2
modeCode ModeReload = 3
modeCode ModeInvestigate = 4

||| The mode a code names. Total by construction: an unknown code — a host that wrote
||| garbage into those bits, or a future version's mode read by this one — is the
||| neutral mode, because refusing to act is not a behaviour this kernel has.
public export
modeFromCode : Nat -> Mode
modeFromCode 0 = ModeAdvance
modeFromCode 1 = ModeEngage
modeFromCode 2 = ModeEvade
modeFromCode 3 = ModeReload
modeFromCode 4 = ModeInvestigate
modeFromCode _ = ModeAdvance

--------------------------------------------------------------------------------
-- The margin
--------------------------------------------------------------------------------

||| How much a challenger must beat the incumbent by, in the Q16.16 units the scores
||| use: 8192 is 0.125. Larger than the gap between the two closest scores (attack
||| 52428 and flee 58982 differ by 6554), and smaller than the one precedence that must
||| survive commitment — which is why `reloadOutranksAnEngagedAgent` below is a theorem
||| and not a hope: reload clears the margin, a wound does not.
|||
||| Deliberately NOT emitted into `ee.h`: like the utility weights, this is policy, not
||| ABI (ADR-0010 §3). A host that knows the margin is a host that has frozen it.
public export
stickiness : Nat
stickiness = 8192

--------------------------------------------------------------------------------
-- Which mode a moment argues for
--------------------------------------------------------------------------------

||| The mode an action belongs to. `Nothing` for the actions that are not modes — HOLD,
||| IDLE, TAKE_COVER, REGROUP — and for anything the ABI grows later, which then has to
||| be given a mode deliberately rather than inheriting one.
public export
actionMode : Action -> Maybe Mode
actionMode ActReload = Just ModeReload
actionMode ActFlee = Just ModeEvade
actionMode ActAttack = Just ModeEngage
actionMode ActInvestigate = Just ModeInvestigate
actionMode ActAdvance = Just ModeAdvance
actionMode ActHold = Nothing
actionMode ActIdle = Nothing
actionMode ActTakeCover = Nothing
actionMode ActRegroup = Nothing

||| The mode behind each action, for scoring. Total over the five modes.
public export
modeAction : Mode -> Action
modeAction ModeReload = ActReload
modeAction ModeEvade = ActFlee
modeAction ModeEngage = ActAttack
modeAction ModeInvestigate = ActInvestigate
modeAction ModeAdvance = ActAdvance

||| The modes this moment offers, in tie-break order.
|||
||| Built from `Abi.Utility.candidates` rather than re-derived, so the one moment with a
||| candidate set of exactly one (nothing visible, a fresh lead: ADR-0010 §4) has a mode
||| set of exactly one too. If that rule changes it changes in one place, and this
||| module cannot drift from it.
public export
modeCandidates : Situation -> List Mode
modeCandidates s = modesOf (candidates s)
  where
    modesOf : List Action -> List Mode
    modesOf [] = []
    modesOf (a :: as) = case actionMode a of
                          Nothing => modesOf as
                          Just m => m :: modesOf as

||| A mode's score: its action's utility, plus the margin if it is what the agent is
||| already doing. The bonus is the entire mechanism — there is no counter anywhere.
public export
modeScore : Mode -> Mode -> Situation -> Nat
modeScore incumbent m s =
  scoreOf (modeAction m) s + (if eqMode m incumbent then stickiness else 0)

||| The best mode in a list, taking the earliest among equals.
public export
bestMode : Mode -> Mode -> Nat -> List Mode -> Situation -> (Mode, Nat)
bestMode incumbent best bestSc [] s = (best, bestSc)
bestMode incumbent best bestSc (m :: ms) s =
  let sc = modeScore incumbent m s in
  if sc > bestSc then bestMode incumbent m sc ms s
                 else bestMode incumbent best bestSc ms s

||| The mode the agent is in after this moment.
public export
nextMode : Mode -> Situation -> Mode
nextMode incumbent s = fst (bestMode incumbent ModeAdvance 0 (modeCandidates s) s)

--------------------------------------------------------------------------------
-- The encoding is what the header says it is
--------------------------------------------------------------------------------

export
modeShiftIsOne : Abi.Modes.modeShift = 1
modeShiftIsOne = Refl

export
modeMaskIsFourteen : Abi.Modes.modeMask = 14
modeMaskIsFourteen = Refl

||| Five modes fit in three bits with room for three more, so this slice does not consume
||| the whole field: an ABI that runs out of flag bits is an ABI that has to break its
||| layout to grow.
export
modesFitInTheMask : So (modeCode ModeInvestigate < 7)
modesFitInTheMask = Oh

export
advanceIsCodeZero : modeCode ModeAdvance = 0
advanceIsCodeZero = Refl

export
investigateIsCodeFour : modeCode ModeInvestigate = 4
investigateIsCodeFour = Refl

||| Decoding what was encoded gives back the mode, in the direction the kernel uses: it
||| writes the code this tick and reads it back next tick.
export
codeRoundTripsThroughTheMode : (modeFromCode (modeCode ModeInvestigate)) = ModeInvestigate
codeRoundTripsThroughTheMode = Refl

||| A code from nowhere decodes to the neutral mode rather than to a behaviour.
export
garbageDecodesToNeutral : modeFromCode 99 = ModeAdvance
garbageDecodesToNeutral = Refl

||| The model and the wire say the same thing. `Abi.Types` owns the constants the
||| header is generated from; this module owns the codes the kernel reasons with, and
||| the two are the same fact written twice — so it is pinned here, where a drift fails
||| to compile instead of shipping a kernel whose modes disagree with its own header.
export
wireAgreesOnTheEncoding :
  ( Abi.Modes.modeShift, Abi.Modes.modeMask ) = ( Abi.Types.agentModeShift, Abi.Types.agentModeMask )
wireAgreesOnTheEncoding = Refl

export
wireAgreesOnEveryCode :
  ( (modeCode ModeAdvance,    Abi.Types.agentModeAdvance)
  , (modeCode ModeEngage,     Abi.Types.agentModeEngage)
  , (modeCode ModeEvade,      Abi.Types.agentModeEvade)
  , (modeCode ModeReload,     Abi.Types.agentModeReload)
  , (modeCode ModeInvestigate, Abi.Types.agentModeInvestigate) )
  = ( (0, 0), (1, 1), (2, 2), (3, 3), (4, 4) )
wireAgreesOnEveryCode = Refl

--------------------------------------------------------------------------------
-- Commitment: what the margin holds, and what it cannot
--------------------------------------------------------------------------------
-- Each theorem gives `nextMode` a real moment and states the mode it lands in. The
-- left-hand sides reduce, so these are checks on the code rather than descriptions of
-- it. Together they are the argument that this layer damps oscillation without becoming
-- blindness: a mode is held while a challenger is close, released the moment its own
-- precondition fails, and never held against a precedence that must survive.

||| THE FLAPPING CASE, and the reason this slice exists. The agent is wounded and the
||| threat is at 40000: flee applies (58982) and so does attack (52428 + 8192 = 60620
||| because the agent is already engaged). The wound does not break the engagement — a
||| player who chips an enemy's health does not get a coin-flip every tick.
export
engagedAgentHoldsThroughAWound :
  nextMode ModeEngage (MkSituation True 40000 True False False) = ModeEngage
engagedAgentHoldsThroughAWound = Refl

||| But commitment is not blindness: a wounded agent that is NOT yet engaged breaks off,
||| because flee is the highest score on the board and there is no margin to pay.
export
freshlyWoundedAgentDisengages :
  nextMode ModeAdvance (MkSituation True 40000 True False False) = ModeEvade
freshlyWoundedAgentDisengages = Refl

||| And an evading agent re-engages as soon as the wound is gone, because the evade
||| score returns to zero and the margin cannot hold a mode that no longer applies.
export
healedAgentReengages :
  nextMode ModeEvade (MkSituation True 40000 False False False) = ModeEngage
healedAgentReengages = Refl

||| The precedence that MUST survive commitment: no ammo reloads even when the agent is
||| mid-fight and wounded. Reload (65536) clears the engaged bonus (60620); this is the
||| corrected reading of the precedence `Abi.Memory` got wrong once (ADR-0010 §4), now
||| stated where a mode could have quietly overridden it.
export
reloadOutranksAnEngagedAgent :
  nextMode ModeEngage (MkSituation True 40000 True True False) = ModeReload
reloadOutranksAnEngagedAgent = Refl

||| A mode that no longer applies is dropped however comfortable it was: a contact at
||| 196608 is outside attack range, so the attack score is zero and engagement ends
||| rather than coasting on the margin.
export
engagementEndsWhenTheContactLeaves :
  nextMode ModeEngage (MkSituation True 196608 False False False) = ModeAdvance
engagementEndsWhenTheContactLeaves = Refl

||| ADR-0010 §4, preserved through this layer: with nothing visible and a fresh lead
||| the mode set is exactly one mode, so commitment cannot reintroduce the `t = 85`
||| collision that slice was about.
export
theMemorySingletonSurvivesCommitment :
  nextMode ModeEngage (MkSituation False 0 False True True) = ModeInvestigate
theMemorySingletonSurvivesCommitment = Refl

||| And with nothing to see and nothing remembered, the agent advances — from any mode.
||| Stated for the two extremes of the mode set so the claim is not about one incumbent.
export
blindAgentsAdvanceWhateverTheyWereDoing :
  ( nextMode ModeAdvance (MkSituation False 0 False False False)
  , nextMode ModeEvade   (MkSituation False 0 False False False) )
  = (ModeAdvance, ModeAdvance)
blindAgentsAdvanceWhateverTheyWereDoing = Refl
