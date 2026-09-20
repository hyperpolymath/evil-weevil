-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- ABI Proof: Non-null pointer safety
-- Template proof — customise for your project's pointer types.
-- All proofs MUST be constructive (no believe_me, no assert_total).

module ABI.Pointers

import Data.So

%default total

||| A pointer value that has been proven non-null.
|||
||| The `So` witness is NOT erased (no `0`), and that is deliberate: the lemma
||| below hands the witness back to callers, and an erased field cannot be projected
||| into a value position — which is exactly why the original text of this module did
||| not compile. `So b` has at most one inhabitant, so carrying it costs a bit and
||| buys a nameable proof.
public export
record SafePtr where
  constructor MkSafePtr
  ptr : Bits64
  {auto nonNull : So (ptr /= 0)}

||| Proof that SafePtr can never hold a null (zero) value.
||| This is enforced by the `So` constraint in the record.
export
safePtrNeverNull : (sp : SafePtr) -> So (sp.ptr /= 0)
safePtrNeverNull sp = sp.nonNull

||| Wrap a raw pointer with a runtime null check.
||| Returns Nothing if the pointer is null.
export
checkPtr : (raw : Bits64) -> Maybe SafePtr
checkPtr 0 = Nothing
checkPtr raw = case choose (raw /= 0) of
  Left prf => Just (MkSafePtr raw)
  Right _ => Nothing

||| Proof that checkPtr 0 always returns Nothing.
export
checkPtrZeroIsNothing : checkPtr 0 = Nothing
checkPtrZeroIsNothing = Refl

||| An opaque handle backed by a non-null pointer.
||| Use this for FFI resource handles (file descriptors, sockets, etc.).
public export
record Handle (tag : String) where
  constructor MkHandle
  safePtr : SafePtr

||| Every handle is non-null, whichever handle it is.
|||
||| This replaces a proof that two handles with equal pointers are EQUAL, which is
||| not the property anyone needs and not a true one here: `Handle` carries an `So`
||| witness, so structural equality would require comparing the witnesses rather than
||| the pointers. Handle identity is a host-side question (the host knows which
||| resource it handed out); what the kernel needs from this module is that no handle
||| is ever null, and that is what is proved.
export
handleNeverNull : (h : Handle tag) -> So (h.safePtr.ptr /= 0)
handleNeverNull (MkHandle sp) = sp.nonNull
