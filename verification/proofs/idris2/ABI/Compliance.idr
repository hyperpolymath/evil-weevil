-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- ABI Proof: C ABI compliance
-- Proves that struct layouts are C ABI compliant.
-- All proofs MUST be constructive (no believe_me, no assert_total).

module ABI.Compliance

-- Data.Nat is imported HERE, not merely in ABI.Layout, because this module writes
-- types that unfold into `LTE` (`FieldInBounds` is `LTE (offset + size) sz`). An
-- import is not transitive, and the failure it produces is misleading: Idris2
-- reports "Data.Nat.LTE not a data type" — as though the type were malformed —
-- rather than "undefined name LTE". That is the error that kept this module
-- quarantined.
import Data.Nat
import ABI.Layout
import ABI.Platform

%default total

||| Evidence that every field in a layout is correctly aligned.
public export
data AllFieldsAligned : List StructField -> Type where
  AFANil  : AllFieldsAligned []
  ||| The alignment witness travels with the field: `FieldAligned` needs to know the
  ||| alignment is non-zero, and a record field's alignment is only known once a
  ||| concrete field is in hand.
  AFACons : {auto 0 ok : NonZero (fieldAlignment f)} ->
            FieldAligned f @{ok} -> AllFieldsAligned fs -> AllFieldsAligned (f :: fs)

||| Evidence that every field is within the struct bounds.
public export
data AllFieldsInBounds : (size : Nat) -> List StructField -> Type where
  AFBNil  : AllFieldsInBounds size []
  AFBCons : FieldInBounds size f -> AllFieldsInBounds size fs -> AllFieldsInBounds size (f :: fs)

||| A struct layout is C ABI compliant when:
||| 1. All fields are aligned to their natural alignment
||| 2. All fields are within bounds of the struct size
||| 3. The struct size is a multiple of the struct alignment
public export
record CABICompliant (layout : StructLayout) where
  constructor MkCompliant
  fieldsAligned  : AllFieldsAligned (layoutFields layout)
  fieldsInBounds : AllFieldsInBounds (layoutSize layout) (layoutFields layout)
  {auto 0 ok : NonZero (layoutAlignment layout)}
  sizeAligned    : modNatNZ (layoutSize layout) (layoutAlignment layout) ok = 0

||| An empty struct is trivially compliant (size=1, alignment=1).
export
emptyStructCompliant : CABICompliant (MkLayout "empty" [] 1 1)
emptyStructCompliant = MkCompliant AFANil AFBNil Refl
