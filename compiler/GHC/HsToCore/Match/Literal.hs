
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998


Pattern-matching literal patterns
-}

module GHC.HsToCore.Match.Literal
   ( dsLit, dsOverLit, hsLitKey
   , tidyLitPat, tidyNPat
   , matchLiterals, matchNPlusKPats, matchNPats
   , warnAboutIdentities
   , warnAboutOverflowedOverLit, warnAboutOverflowedLit
   , warnAboutEmptyEnumerations
   )
where

import GHC.Prelude
import GHC.Platform

import {-# SOURCE #-} GHC.HsToCore.Match ( match )
import {-# SOURCE #-} GHC.HsToCore.Expr  ( dsExpr, dsSyntaxExpr )

import GHC.HsToCore.Monad
import GHC.HsToCore.Utils

import GHC.Hs

import GHC.Types.Id
import GHC.Types.SourceText
import GHC.Core
import GHC.Core.Make
import GHC.Core.TyCon
import GHC.Core.DataCon
import GHC.Tc.Utils.Zonk ( shortCutLit )
import GHC.Tc.Utils.TcType
import GHC.Types.Name
import GHC.Core.Type
import GHC.Builtin.Names
import GHC.Builtin.Types
import GHC.Builtin.Types.Prim
import GHC.Types.Literal
import GHC.Types.SrcLoc
import GHC.Utils.Outputable as Outputable
import GHC.Driver.Session
import GHC.Utils.Misc
import GHC.Utils.Panic
import GHC.Utils.Panic.Plain
import GHC.Data.FastString
import qualified GHC.LanguageExtensions as LangExt
import GHC.Core.FamInstEnv ( FamInstEnvs, normaliseType )

import Control.Monad
import Data.Int
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NEL
import Data.Word
import GHC.Real ( Ratio(..), numerator, denominator )

{-
************************************************************************
*                                                                      *
                Desugaring literals
 [used to be in GHC.HsToCore.Expr, but GHC.HsToCore.Quote needs it,
  and it's nice to avoid a loop]
*                                                                      *
************************************************************************

We give int/float literals type @Integer@ and @Rational@, respectively.
The typechecker will (presumably) have put \tr{from{Integer,Rational}s}
around them.

ToDo: put in range checks for when converting ``@i@''
(or should that be in the typechecker?)

For numeric literals, we try to detect there use at a standard type
(@Int@, @Float@, etc.) are directly put in the right constructor.
[NB: down with the @App@ conversion.]

See also below where we look for @DictApps@ for \tr{plusInt}, etc.
-}

dsLit :: HsLit GhcRn -> DsM CoreExpr
dsLit l = do
  dflags <- getDynFlags
  let platform = targetPlatform dflags
  case l of
    HsStringPrim _ s -> return (Lit (LitString s))
    HsCharPrim   _ c -> return (Lit (LitChar c))
    HsIntPrim    _ i -> return (Lit (mkLitIntWrap platform i))
    HsWordPrim   _ w -> return (Lit (mkLitWordWrap platform w))
    HsInt64Prim  _ i -> return (Lit (mkLitInt64Wrap i))
    HsWord64Prim _ w -> return (Lit (mkLitWord64Wrap w))

    -- This can be slow for very large literals. See Note [FractionalLit representation]
    -- and #15646
    HsFloatPrim  _ fl -> return (Lit (LitFloat (rationalFromFractionalLit fl)))
    HsDoublePrim _ fl -> return (Lit (LitDouble (rationalFromFractionalLit fl)))
    HsChar _ c       -> return (mkCharExpr c)
    HsString _ str   -> mkStringExprFS str
    HsInteger _ i _  -> return (mkIntegerExpr i)
    HsInt _ i        -> return (mkIntExpr platform (il_value i))
    HsRat _ fl ty    -> dsFractionalLitToRational fl ty

{-
Note [FractionalLit representation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
There is a fun wrinkle to this, we used to simply compute the value
for these literals and store it as `Rational`. While this might seem
reasonable it meant typechecking literals of extremely large numbers
wasn't possible. This happend for example in #15646.

There a user would write in GHCi e.g. `:t 1e1234111111111111111111111`
which would trip up the compiler. The reason being we would parse it as
<Literal of value n>. Try to compute n, which would run out of memory
for truly large numbers, or take far too long for merely large ones.

To fix this we instead now store the significand and exponent of the
literal instead. Depending on the size of the exponent we then defer
the computation of the Rational value, potentially up to runtime of the
program! There are still cases left were we might compute large rationals
but it's a lot rarer then.

The current state of affairs for large literals is:
* Typechecking: Will produce a FractionalLit
* Desugaring a large overloaded literal to Float/Double *is* done
  at compile time. So can still fail. But this only matters for values too large
  to be represented as float anyway.
* Converting overloaded literals to a value of *Rational* is done at *runtime*.
  If such a value is then demanded at runtime the program might hang or run out of
  memory. But that is perhaps expected and acceptable.
* TH might also evaluate the literal even when overloaded.
  But there a user should be able to work around #15646 by
  generating a call to `mkRationalBase10/2` for large literals instead.


Note [FractionalLit representation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For fractional literals, like 1.3 or 0.79e22, we do /not/ represent
them within the compiler as a Rational.  Doing so would force the
compiler to compute a huge Rational for 2.3e300000000000, at compile
time (#15646)!

So instead we represent fractional literals as a FractionalLit,
in which we record the significand and exponent separately.  Then
we can compute the huge Rational at /runtime/, by emitting code
for
       mkRationalBase10 2.3 300000000000

where mkRationalBase10 is defined in the library GHC.Real

The moving parts are here:

* Parsing, renaming, typechecking: use FractionalLit, in which the
  significand and exponent are represented separately.

* Desugaring.  Remember that a fractional literal like 54.4e20 has type
     Fractional a => a

  - For fractional literals whose type turns out to be Float/Double,
    we desugar to a Float/Double literal at /compile time/.
    This conversion can still fail. But this only matters for values
    too large to be represented as float anyway.  See dsLit in
    GHC.HsToCore.Match.Literal

  - For fractional literals whose type turns out to be Rational, we
    desugar the literal to a call of `mkRationalBase10` (etc for hex
    literals), so that we only compute the Rational at /run time/.  If
    this value is then demanded at runtime the program might hang or
    run out of memory. But that is perhaps expected and acceptable.
    See dsFractionalLitToRational in GHC.HsToCore.Match.Literal

  - For fractional literals whose type isn't one of the above, we just
    call the typeclass method `fromRational`.  But to do that we need
    the rational to give to it, and we compute that at runtime, as
    above.

* Template Haskell definitions are also problematic. While the TH code
  works as expected once it's spliced into a program it will compute the
  value of the large literal.
  But there a user should be able to work around #15646
  by having their TH code generating a call to `mkRationalBase[10/2]` for
  large literals  instead.

-}

-- | See Note [FractionalLit representation]
dsFractionalLitToRational :: FractionalLit -> Type -> DsM CoreExpr
dsFractionalLitToRational fl@FL{ fl_signi = signi, fl_exp = exp, fl_exp_base = base } ty
  -- We compute "small" rationals here and now
  | abs exp <= 100
  = let !val   = rationalFromFractionalLit fl
        !num   = mkIntegerExpr (numerator val)
        !denom = mkIntegerExpr (denominator val)
        (ratio_data_con, integer_ty)
            = case tcSplitTyConApp ty of
                    (tycon, [i_ty]) -> assert (isIntegerTy i_ty && tycon `hasKey` ratioTyConKey)
                                       (head (tyConDataCons tycon), i_ty)
                    x -> pprPanic "dsLit" (ppr x)
    in return $! (mkCoreConApps ratio_data_con [Type integer_ty, num, denom])
  -- Large rationals will be computed at runtime.
  | otherwise
  = do
      let mkRationalName = case base of
                             Base2 -> mkRationalBase2Name
                             Base10 -> mkRationalBase10Name
      mkRational <- dsLookupGlobalId mkRationalName
      litR <- dsRational signi
      let litE = mkIntegerExpr exp
      return (mkCoreApps (Var mkRational) [litR, litE])

dsRational :: Rational -> DsM CoreExpr
dsRational (n :% d) = do
  dcn <- dsLookupDataCon ratioDataConName
  let cn = mkIntegerExpr n
  let dn = mkIntegerExpr d
  return $ mkCoreConApps dcn [Type integerTy, cn, dn]


dsOverLit :: HsOverLit GhcTc -> DsM CoreExpr
-- ^ Post-typechecker, the 'HsExpr' field of an 'OverLit' contains
-- (an expression for) the literal value itself.
dsOverLit (OverLit { ol_val = val, ol_ext = OverLitTc rebindable ty
                   , ol_witness = witness }) = do
  dflags <- getDynFlags
  let platform = targetPlatform dflags
  case shortCutLit platform val ty of
    Just expr | not rebindable -> dsExpr expr        -- Note [Literal short cut]
    _                          -> dsExpr witness

{-
Note [Literal short cut]
~~~~~~~~~~~~~~~~~~~~~~~~
The type checker tries to do this short-cutting as early as possible, but
because of unification etc, more information is available to the desugarer.
And where it's possible to generate the correct literal right away, it's
much better to do so.


************************************************************************
*                                                                      *
                 Warnings about overflowed literals
*                                                                      *
************************************************************************

Warn about functions like toInteger, fromIntegral, that convert
between one type and another when the to- and from- types are the
same.  Then it's probably (albeit not definitely) the identity
-}

warnAboutIdentities :: DynFlags -> Id -> Type -> DsM ()
warnAboutIdentities dflags conv_fn type_of_conv
  | wopt Opt_WarnIdentities dflags
  , idName conv_fn `elem` conversionNames
  , Just (_, arg_ty, res_ty) <- splitFunTy_maybe type_of_conv
  , arg_ty `eqType` res_ty  -- So we are converting  ty -> ty
  = diagnosticDs (WarningWithFlag Opt_WarnIdentities)
                 (vcat [ text "Call of" <+> ppr conv_fn <+> dcolon <+> ppr type_of_conv
                       , nest 2 $ text "can probably be omitted"
                 ])
warnAboutIdentities _ _ _ = return ()

conversionNames :: [Name]
conversionNames
  = [ toIntegerName, toRationalName
    , fromIntegralName, realToFracName ]
 -- We can't easily add fromIntegerName, fromRationalName,
 -- because they are generated by literals


-- | Emit warnings on overloaded integral literals which overflow the bounds
-- implied by their type.
warnAboutOverflowedOverLit :: HsOverLit GhcTc -> DsM ()
warnAboutOverflowedOverLit hsOverLit = do
  dflags <- getDynFlags
  fam_envs <- dsGetFamInstEnvs
  warnAboutOverflowedLiterals dflags $
      getIntegralLit hsOverLit >>= getNormalisedTyconName fam_envs

-- | Emit warnings on integral literals which overflow the bounds implied by
-- their type.
warnAboutOverflowedLit :: HsLit GhcTc -> DsM ()
warnAboutOverflowedLit hsLit = do
  dflags <- getDynFlags
  warnAboutOverflowedLiterals dflags $
      getSimpleIntegralLit hsLit >>= getTyconName

-- | Emit warnings on integral literals which overflow the bounds implied by
-- their type.
warnAboutOverflowedLiterals
  :: DynFlags
  -> Maybe (Integer, Name)  -- ^ the literal value and name of its tycon
  -> DsM ()
warnAboutOverflowedLiterals dflags lit
 | wopt Opt_WarnOverflowedLiterals dflags
 , Just (i, tc) <- lit
 = if
    -- These only show up via the 'HsOverLit' route
    | tc == intTyConName        -> check i tc minInt         maxInt
    | tc == wordTyConName       -> check i tc minWord        maxWord
    | tc == int8TyConName       -> check i tc (min' @Int8)   (max' @Int8)
    | tc == int16TyConName      -> check i tc (min' @Int16)  (max' @Int16)
    | tc == int32TyConName      -> check i tc (min' @Int32)  (max' @Int32)
    | tc == int64TyConName      -> check i tc (min' @Int64)  (max' @Int64)
    | tc == word8TyConName      -> check i tc (min' @Word8)  (max' @Word8)
    | tc == word16TyConName     -> check i tc (min' @Word16) (max' @Word16)
    | tc == word32TyConName     -> check i tc (min' @Word32) (max' @Word32)
    | tc == word64TyConName     -> check i tc (min' @Word64) (max' @Word64)
    | tc == naturalTyConName    -> checkPositive i tc

    -- These only show up via the 'HsLit' route
    | tc == intPrimTyConName    -> check i tc minInt         maxInt
    | tc == wordPrimTyConName   -> check i tc minWord        maxWord
    | tc == int8PrimTyConName   -> check i tc (min' @Int8)   (max' @Int8)
    | tc == int16PrimTyConName  -> check i tc (min' @Int16)  (max' @Int16)
    | tc == int32PrimTyConName  -> check i tc (min' @Int32)  (max' @Int32)
    | tc == int64PrimTyConName  -> check i tc (min' @Int64)  (max' @Int64)
    | tc == word8PrimTyConName  -> check i tc (min' @Word8)  (max' @Word8)
    | tc == word16PrimTyConName -> check i tc (min' @Word16) (max' @Word16)
    | tc == word32PrimTyConName -> check i tc (min' @Word32) (max' @Word32)
    | tc == word64PrimTyConName -> check i tc (min' @Word64) (max' @Word64)

    | otherwise -> return ()

  | otherwise = return ()
  where
    -- use target Int/Word sizes! See #17336
    platform          = targetPlatform dflags
    (minInt,maxInt)   = (platformMinInt platform, platformMaxInt platform)
    (minWord,maxWord) = (0,                       platformMaxWord platform)

    min' :: forall a. (Integral a, Bounded a) => Integer
    min' = fromIntegral (minBound :: a)

    max' :: forall a. (Integral a, Bounded a) => Integer
    max' = fromIntegral (maxBound :: a)

    checkPositive :: Integer -> Name -> DsM ()
    checkPositive i tc
      = when (i < 0) $
        diagnosticDs (WarningWithFlag Opt_WarnOverflowedLiterals)
                     (vcat [ text "Literal" <+> integer i
                             <+> text "is negative but" <+> ppr tc
                             <+> text "only supports positive numbers"
                           ])

    check i tc minB maxB
      = when (i < minB || i > maxB) $
        diagnosticDs (WarningWithFlag Opt_WarnOverflowedLiterals)
                     (vcat [ text "Literal" <+> integer i
                             <+> text "is out of the" <+> ppr tc <+> text "range"
                             <+> integer minB <> text ".." <> integer maxB
                           , sug ])
      where
        sug | minB == -i   -- Note [Suggest NegativeLiterals]
            , i > 0
            , not (xopt LangExt.NegativeLiterals dflags)
            = text "If you are trying to write a large negative literal, use NegativeLiterals"
            | otherwise = Outputable.empty

{-
Note [Suggest NegativeLiterals]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If you write
  x :: Int8
  x = -128
it'll parse as (negate 128), and overflow.  In this case, suggest NegativeLiterals.
We get an erroneous suggestion for
  x = 128
but perhaps that does not matter too much.
-}

warnAboutEmptyEnumerations :: FamInstEnvs -> DynFlags -> LHsExpr GhcTc
                           -> Maybe (LHsExpr GhcTc)
                           -> LHsExpr GhcTc -> DsM ()
-- ^ Warns about @[2,3 .. 1]@ or @['b' .. 'a']@ which return the empty list.
-- For numeric literals, only works for integral types, not floating point.
warnAboutEmptyEnumerations fam_envs dflags fromExpr mThnExpr toExpr
  | not $ wopt Opt_WarnEmptyEnumerations dflags
  = return ()
  -- Numeric Literals
  | Just from_ty@(from',_) <- getLHsIntegralLit fromExpr
  , Just (_, tc)           <- getNormalisedTyconName fam_envs from_ty
  , Just mThn'             <- traverse getLHsIntegralLit mThnExpr
  , Just (to',_)           <- getLHsIntegralLit toExpr
  = do
      let
        check :: forall a. (Integral a, Num a) => DsM ()
        check = when (null enumeration) raiseWarning
          where
            enumeration = case mThn of
              Nothing  -> [from      .. to]
              Just thn -> [from, thn .. to]
            wrap :: forall a. (Integral a, Num a) => Integer -> Integer
            wrap i = toInteger (fromIntegral i :: a)
            from = wrap @a from'
            to   = wrap @a to'
            mThn = fmap (wrap @a . fst) mThn'

      platform <- targetPlatform <$> getDynFlags
         -- Be careful to use target Int/Word sizes! cf #17336
      if | tc == intTyConName     -> case platformWordSize platform of
                                      PW4 -> check @Int32
                                      PW8 -> check @Int64
         | tc == wordTyConName    -> case platformWordSize platform of
                                      PW4 -> check @Word32
                                      PW8 -> check @Word64
         | tc == int8TyConName    -> check @Int8
         | tc == int16TyConName   -> check @Int16
         | tc == int32TyConName   -> check @Int32
         | tc == int64TyConName   -> check @Int64
         | tc == word8TyConName   -> check @Word8
         | tc == word16TyConName  -> check @Word16
         | tc == word32TyConName  -> check @Word32
         | tc == word64TyConName  -> check @Word64
         | tc == integerTyConName -> check @Integer
         | tc == naturalTyConName -> check @Integer
            -- We use 'Integer' because otherwise a negative 'Natural' literal
            -- could cause a compile time crash (instead of a runtime one).
            -- See the T10930b test case for an example of where this matters.
         | otherwise -> return ()

  -- Char literals (#18402)
  | Just fromChar <- getLHsCharLit fromExpr
  , Just mThnChar <- traverse getLHsCharLit mThnExpr
  , Just toChar   <- getLHsCharLit toExpr
  , let enumeration = case mThnChar of
                        Nothing      -> [fromChar          .. toChar]
                        Just thnChar -> [fromChar, thnChar .. toChar]
  = when (null enumeration) raiseWarning

  | otherwise = return ()
  where
    raiseWarning =
      diagnosticDs (WarningWithFlag Opt_WarnEmptyEnumerations) (text "Enumeration is empty")

getLHsIntegralLit :: LHsExpr GhcTc -> Maybe (Integer, Type)
-- ^ See if the expression is an 'Integral' literal.
getLHsIntegralLit (L _ e) = go e
  where
    go (HsPar _ _ e _)        = getLHsIntegralLit e
    go (HsOverLit _ over_lit) = getIntegralLit over_lit
    go (HsLit _ lit)          = getSimpleIntegralLit lit

    -- Remember to look through automatically-added tick-boxes! (#8384)
    go (HsTick _ _ e)         = getLHsIntegralLit e
    go (HsBinTick _ _ _ e)    = getLHsIntegralLit e

    -- The literal might be wrapped in a case with -XOverloadedLists
    go (XExpr (WrapExpr (HsWrap _ e))) = go e
    go _ = Nothing

-- | If 'Integral', extract the value and type of the overloaded literal.
-- See Note [Literals and the OverloadedLists extension]
getIntegralLit :: HsOverLit GhcTc -> Maybe (Integer, Type)
getIntegralLit (OverLit { ol_val = HsIntegral i, ol_ext = OverLitTc _ ty })
  = Just (il_value i, ty)
getIntegralLit _ = Nothing

-- | If 'Integral', extract the value and type of the non-overloaded literal.
getSimpleIntegralLit :: HsLit GhcTc -> Maybe (Integer, Type)
getSimpleIntegralLit (HsInt _ IL{ il_value = i }) = Just (i, intTy)
getSimpleIntegralLit (HsIntPrim _ i)    = Just (i, intPrimTy)
getSimpleIntegralLit (HsWordPrim _ i)   = Just (i, wordPrimTy)
getSimpleIntegralLit (HsInt64Prim _ i)  = Just (i, int64PrimTy)
getSimpleIntegralLit (HsWord64Prim _ i) = Just (i, word64PrimTy)
getSimpleIntegralLit (HsInteger _ i ty) = Just (i, ty)
getSimpleIntegralLit _ = Nothing

-- | Extract the Char if the expression is a Char literal.
getLHsCharLit :: LHsExpr GhcTc -> Maybe Char
getLHsCharLit (L _ (HsPar _ _ e _))        = getLHsCharLit e
getLHsCharLit (L _ (HsTick _ _ e))         = getLHsCharLit e
getLHsCharLit (L _ (HsBinTick _ _ _ e))    = getLHsCharLit e
getLHsCharLit (L _ (HsLit _ (HsChar _ c))) = Just c
getLHsCharLit _ = Nothing

-- | Convert a pair (Integer, Type) to (Integer, Name) after eventually
-- normalising the type
getNormalisedTyconName :: FamInstEnvs -> (Integer, Type) -> Maybe (Integer, Name)
getNormalisedTyconName fam_envs (i,ty)
    | Just tc <- tyConAppTyCon_maybe (normaliseNominal fam_envs ty)
    = Just (i, tyConName tc)
    | otherwise = Nothing
  where
    normaliseNominal :: FamInstEnvs -> Type -> Type
    normaliseNominal fam_envs ty = snd $ normaliseType fam_envs Nominal ty

-- | Convert a pair (Integer, Type) to (Integer, Name) without normalising
-- the type
getTyconName :: (Integer, Type) -> Maybe (Integer, Name)
getTyconName (i,ty)
  | Just tc <- tyConAppTyCon_maybe ty = Just (i, tyConName tc)
  | otherwise = Nothing

{-
Note [Literals and the OverloadedLists extension]
~~~~
Consider the Literal `[256] :: [Data.Word.Word8]`

When the `OverloadedLists` extension is not active, then the `ol_ext` field
in the `OverLitTc` record that is passed to the function `getIntegralLit`
contains the type `Word8`. This is a simple type, and we can use its
type constructor immediately for the `warnAboutOverflowedLiterals` function.

When the `OverloadedLists` extension is active, then the `ol_ext` field
contains the type family `Item [Word8]`. The function `nomaliseType` is used
to convert it to the needed type `Word8`.
-}

{-
************************************************************************
*                                                                      *
        Tidying lit pats
*                                                                      *
************************************************************************
-}

tidyLitPat :: HsLit GhcTc -> Pat GhcTc
-- Result has only the following HsLits:
--      HsIntPrim, HsWordPrim, HsCharPrim, HsFloatPrim
--      HsDoublePrim, HsStringPrim, HsString
--  * HsInteger, HsRat, HsInt can't show up in LitPats
--  * We get rid of HsChar right here
tidyLitPat (HsChar src c) = unLoc (mkCharLitPat src c)
tidyLitPat (HsString src s)
  | lengthFS s <= 1     -- Short string literals only
  = unLoc $ foldr (\c pat -> mkPrefixConPat consDataCon
                                             [mkCharLitPat src c, pat] [charTy])
                  (mkNilPat charTy) (unpackFS s)
        -- The stringTy is the type of the whole pattern, not
        -- the type to instantiate (:) or [] with!
tidyLitPat lit = LitPat noExtField lit

----------------
tidyNPat :: HsOverLit GhcTc -> Maybe (SyntaxExpr GhcTc) -> SyntaxExpr GhcTc
         -> Type
         -> Pat GhcTc
tidyNPat (OverLit (OverLitTc False ty) val _) mb_neg _eq outer_ty
        -- False: Take short cuts only if the literal is not using rebindable syntax
        --
        -- Once that is settled, look for cases where the type of the
        -- entire overloaded literal matches the type of the underlying literal,
        -- and in that case take the short cut
        -- NB: Watch out for weird cases like #3382
        --        f :: Int -> Int
        --        f "blah" = 4
        --     which might be ok if we have 'instance IsString Int'
        --
  | not type_change, isIntTy ty,    Just int_lit <- mb_int_lit
                 = mk_con_pat intDataCon    (HsIntPrim    NoSourceText int_lit)
  | not type_change, isWordTy ty,   Just int_lit <- mb_int_lit
                 = mk_con_pat wordDataCon   (HsWordPrim   NoSourceText int_lit)
  | not type_change, isStringTy ty, Just str_lit <- mb_str_lit
                 = tidyLitPat (HsString NoSourceText str_lit)
     -- NB: do /not/ convert Float or Double literals to F# 3.8 or D# 5.3
     -- If we do convert to the constructor form, we'll generate a case
     -- expression on a Float# or Double# and that's not allowed in Core; see
     -- #9238 and Note [Rules for floating-point comparisons] in GHC.Core.Opt.ConstantFold
  where
    -- Sometimes (like in test case
    -- overloadedlists/should_run/overloadedlistsrun04), the SyntaxExprs include
    -- type-changing wrappers (for example, from Id Int to Int, for the identity
    -- type family Id). In these cases, we can't do the short-cut.
    type_change = not (outer_ty `eqType` ty)

    mk_con_pat :: DataCon -> HsLit GhcTc -> Pat GhcTc
    mk_con_pat con lit
      = unLoc (mkPrefixConPat con [noLocA $ LitPat noExtField lit] [])

    mb_int_lit :: Maybe Integer
    mb_int_lit = case (mb_neg, val) of
                   (Nothing, HsIntegral i) -> Just (il_value i)
                   (Just _,  HsIntegral i) -> Just (-(il_value i))
                   _ -> Nothing

    mb_str_lit :: Maybe FastString
    mb_str_lit = case (mb_neg, val) of
                   (Nothing, HsIsString _ s) -> Just s
                   _ -> Nothing

tidyNPat over_lit mb_neg eq outer_ty
  = NPat outer_ty (noLoc over_lit) mb_neg eq

{-
************************************************************************
*                                                                      *
                Pattern matching on LitPat
*                                                                      *
************************************************************************
-}

matchLiterals :: NonEmpty Id
              -> Type -- ^ Type of the whole case expression
              -> NonEmpty (NonEmpty EquationInfo) -- ^ All PgLits
              -> DsM (MatchResult CoreExpr)

matchLiterals (var :| vars) ty sub_groups
  = do  {       -- Deal with each group
        ; alts <- mapM match_group sub_groups

                -- Combine results.  For everything except String
                -- we can use a case expression; for String we need
                -- a chain of if-then-else
        ; if isStringTy (idType var) then
            do  { eq_str <- dsLookupGlobalId eqStringName
                ; mrs <- mapM (wrap_str_guard eq_str) alts
                ; return (foldr1 combineMatchResults mrs) }
          else
            return (mkCoPrimCaseMatchResult var ty $ NEL.toList alts)
        }
  where
    match_group :: NonEmpty EquationInfo -> DsM (Literal, MatchResult CoreExpr)
    match_group eqns@(firstEqn :| _)
        = do { dflags <- getDynFlags
             ; let platform = targetPlatform dflags
             ; let LitPat _ hs_lit = firstPat firstEqn
             ; match_result <- match vars ty (NEL.toList $ shiftEqns eqns)
             ; return (hsLitKey platform hs_lit, match_result) }

    wrap_str_guard :: Id -> (Literal,MatchResult CoreExpr) -> DsM (MatchResult CoreExpr)
        -- Equality check for string literals
    wrap_str_guard eq_str (LitString s, mr)
        = do { -- We now have to convert back to FastString. Perhaps there
               -- should be separate LitBytes and LitString constructors?
               let s'  = mkFastStringByteString s
             ; lit    <- mkStringExprFS s'
             ; let pred = mkApps (Var eq_str) [Var var, lit]
             ; return (mkGuardedMatchResult pred mr) }
    wrap_str_guard _ (l, _) = pprPanic "matchLiterals/wrap_str_guard" (ppr l)


---------------------------
hsLitKey :: Platform -> HsLit GhcTc -> Literal
-- Get the Core literal corresponding to a HsLit.
-- It only works for primitive types and strings;
-- others have been removed by tidy
-- For HsString, it produces a LitString, which really represents an _unboxed_
-- string literal; and we deal with it in matchLiterals above. Otherwise, it
-- produces a primitive Literal of type matching the original HsLit.
-- In the case of the fixed-width numeric types, we need to wrap here
-- because Literal has an invariant that the literal is in range, while
-- HsLit does not.
hsLitKey platform (HsIntPrim    _ i)  = mkLitIntWrap  platform i
hsLitKey platform (HsWordPrim   _ w)  = mkLitWordWrap platform w
hsLitKey _        (HsInt64Prim  _ i)  = mkLitInt64Wrap  i
hsLitKey _        (HsWord64Prim _ w)  = mkLitWord64Wrap w
hsLitKey _        (HsCharPrim   _ c)  = mkLitChar            c
-- This following two can be slow. See Note [FractionalLit representation]
hsLitKey _        (HsFloatPrim  _ fl) = mkLitFloat (rationalFromFractionalLit fl)
hsLitKey _        (HsDoublePrim _ fl) = mkLitDouble (rationalFromFractionalLit fl)

hsLitKey _        (HsString _ s)      = LitString (bytesFS s)
hsLitKey _        l                   = pprPanic "hsLitKey" (ppr l)

{-
************************************************************************
*                                                                      *
                Pattern matching on NPat
*                                                                      *
************************************************************************
-}

matchNPats :: NonEmpty Id -> Type -> NonEmpty EquationInfo -> DsM (MatchResult CoreExpr)
matchNPats (var :| vars) ty (eqn1 :| eqns)    -- All for the same literal
  = do  { let NPat _ (L _ lit) mb_neg eq_chk = firstPat eqn1
        ; lit_expr <- dsOverLit lit
        ; neg_lit <- case mb_neg of
                            Nothing  -> return lit_expr
                            Just neg -> dsSyntaxExpr neg [lit_expr]
        ; pred_expr <- dsSyntaxExpr eq_chk [Var var, neg_lit]
        ; match_result <- match vars ty (shiftEqns (eqn1:eqns))
        ; return (mkGuardedMatchResult pred_expr match_result) }

{-
************************************************************************
*                                                                      *
                Pattern matching on n+k patterns
*                                                                      *
************************************************************************

For an n+k pattern, we use the various magic expressions we've been given.
We generate:
\begin{verbatim}
    if ge var lit then
        let n = sub var lit
        in  <expr-for-a-successful-match>
    else
        <try-next-pattern-or-whatever>
\end{verbatim}
-}

matchNPlusKPats :: NonEmpty Id -> Type -> NonEmpty EquationInfo -> DsM (MatchResult CoreExpr)
-- All NPlusKPats, for the *same* literal k
matchNPlusKPats (var :| vars) ty (eqn1 :| eqns)
  = do  { let NPlusKPat _ (L _ n1) (L _ lit1) lit2 ge minus
                = firstPat eqn1
        ; lit1_expr   <- dsOverLit lit1
        ; lit2_expr   <- dsOverLit lit2
        ; pred_expr   <- dsSyntaxExpr ge    [Var var, lit1_expr]
        ; minusk_expr <- dsSyntaxExpr minus [Var var, lit2_expr]
        ; let (wraps, eqns') = mapAndUnzip (shift n1) (eqn1:eqns)
        ; match_result <- match vars ty eqns'
        ; return  (mkGuardedMatchResult pred_expr               $
                   mkCoLetMatchResult (NonRec n1 minusk_expr)   $
                   fmap (foldr1 (.) wraps)                      $
                   match_result) }
  where
    shift n1 eqn@(EqnInfo { eqn_pats = NPlusKPat _ (L _ n) _ _ _ _ : pats })
        = (wrapBind n n1, eqn { eqn_pats = pats })
        -- The wrapBind is a no-op for the first equation
    shift _ e = pprPanic "matchNPlusKPats/shift" (ppr e)
