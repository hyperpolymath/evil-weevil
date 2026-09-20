-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- ABI Proof: Platform-specific type size proofs
-- Proves that C type sizes are correct per platform.
-- All proofs MUST be constructive (no believe_me, no assert_total).

module ABI.Platform

import Data.Nat
import Data.Nat.Order

%default total

||| Supported target platforms for ABI verification.
public export
data Platform = Linux64 | LinuxARM64 | MacOS64 | MacOSARM64
              | Windows64 | FreeBSD64 | WASM32

||| Pointer size in bytes for each platform.
public export
ptrSize : Platform -> Nat
ptrSize WASM32 = 4
ptrSize _ = 8

||| C `int` size in bytes.
public export
cIntSize : Platform -> Nat
cIntSize _ = 4

||| C `size_t` size in bytes (matches pointer size).
public export
cSizeT : Platform -> Nat
cSizeT = ptrSize

||| Proof that size_t always equals pointer size on all platforms.
export
sizeTEqPtrSize : (p : Platform) -> cSizeT p = ptrSize p
sizeTEqPtrSize _ = Refl

||| Proof that pointer size is always 4 or 8 bytes.
export
ptrSizeValid : (p : Platform) -> Either (ptrSize p = 4) (ptrSize p = 8)
ptrSizeValid WASM32 = Left Refl
ptrSizeValid Linux64 = Right Refl
ptrSizeValid LinuxARM64 = Right Refl
ptrSizeValid MacOS64 = Right Refl
ptrSizeValid MacOSARM64 = Right Refl
ptrSizeValid Windows64 = Right Refl
ptrSizeValid FreeBSD64 = Right Refl

||| Proof that C int is always 4 bytes on all platforms.
export
cIntAlways4 : (p : Platform) -> cIntSize p = 4
cIntAlways4 _ = Refl

||| 4 <= 8: `LTESucc` applied four times to `LTEZero : LTE 0 4`.
|||
||| Written out because this base library (0.7.0) has neither `lteRefl` nor
||| `lteSuccRight`, which the template's original text assumed — an Idris1-era or
||| different-base habit that left this module quarantined. The constructors are
||| enough: `LTESucc` adds one to both sides, so four of them take `LTE 0 4` to
||| `LTE 4 8`.
export
fourLeEight : LTE 4 8
fourLeEight = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))

||| 4 <= 4, the reflexive case, built the same way.
export
fourLeFour : LTE 4 4
fourLeFour = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))

||| Proof that pointer size is always at least 4 bytes.
export
ptrSizeAtLeast4 : (p : Platform) -> LTE 4 (ptrSize p)
ptrSizeAtLeast4 WASM32 = fourLeFour
ptrSizeAtLeast4 Linux64 = fourLeEight
ptrSizeAtLeast4 LinuxARM64 = fourLeEight
ptrSizeAtLeast4 MacOS64 = fourLeEight
ptrSizeAtLeast4 MacOSARM64 = fourLeEight
ptrSizeAtLeast4 Windows64 = fourLeEight
ptrSizeAtLeast4 FreeBSD64 = fourLeEight
