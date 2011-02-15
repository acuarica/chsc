{-# LANGUAGE TupleSections, PatternGuards, ViewPatterns #-}
module Evaluator.Evaluate (normalise, step) where

import Evaluator.Deeds
import Evaluator.FreeVars
--import Evaluator.Residualise
import Evaluator.Syntax

import Core.Renaming
import Core.Syntax
import Core.Prelude (trueDataCon, falseDataCon)

import Renaming
import StaticFlags
import Utilities

import qualified Data.Map as M


-- | Non-expansive simplification we can do everywhere safely
--
-- Normalisation only ever releases deeds: it is *never* a net consumer of deeds. So normalisation
-- will never be impeded by a lack of deeds.
normalise :: UnnormalisedState -> State
normalise = snd . step' True

-- | Possibly non-normalising simplification we can only do if we are allowed to by a termination test
--
-- Unlike normalisation, stepping may be a net consumer of deeds and thus be impeded by a lack of them.
step :: State -> Maybe State
step ((step' False . denormalise) -> (reduced, result)) = guard reduced >> return result

step' :: Bool -> UnnormalisedState -> (Bool, State) -- The flag indicates whether we managed to reduce any steps *at all*
step' normalising state =
    (\res@(_reduced, state') -> assertRender (hang (text "step': deeds lost or gained:") 2 (pPrint state $$ pPrint state'))
                                             (noChange (releaseStateDeed state) (releaseStateDeed state')) $
                                assertRender (text "step': FVs") (stateFreeVars state == stateFreeVars state') $
                                -- traceRender (text "normalising" $$ nest 2 (pPrintFullUnnormalisedState state) $$ text "to" $$ nest 2 (pPrintFullState state')) $
                                res) $
    go False state
  where
    go reduced (deeds, h, k, (rn, e)) = case annee e of
        Var x             -> maybe (reduced, (deeds, h, k, (rn, fmap (const (Question x)) e))) (go True) $ force  deeds h k tg (rename rn x);
        Value v           -> maybe (reduced, (deeds, h, k, (rn, fmap (const (Answer v)) e)))   (go True) $ unwind deeds h k tg (rn, v)
        App e1 x2         -> go True (deeds, h, Tagged tg (Apply (rename rn x2))            : k, (rn, e1))
        PrimOp pop []     -> panic "reduced" (text "Nullary primop" <+> pPrint pop <+> text "in input")
        PrimOp pop (e:es) -> go True (deeds, h, Tagged tg (PrimApply pop [] (map (rn,) es)) : k, (rn, e))
        Case e alts       -> go True (deeds, h, Tagged tg (Scrutinise (rn, alts))           : k, (rn, e))
        LetRec xes e      -> go True (allocate (deeds + 1) h k (rn, (xes, e)))
      where tg = annedTag e

    allocate :: Deeds -> Heap -> Stack -> In ([(Var, AnnedTerm)], AnnedTerm) -> UnnormalisedState
    allocate deeds (Heap h ids) k (rn, (xes, e)) = (deeds, Heap (h `M.union` M.map Concrete (M.fromList xes')) ids', k, (rn', e))
      where (ids', rn', xes') = renameBounds (\_ x' -> x') ids rn xes

    prepareValue :: Deeds
                 -> Out Var       -- ^ Name to which the value is bound
                 -> In AnnedValue -- ^ Bound value, which we have *exactly* 1 deed for already that is not recorded in the Deeds itself
                 -> Maybe (Deeds, In AnnedValue) -- Outgoing deeds have that 1 latent deed included in them, and we have claimed deeds for the outgoing value
    prepareValue deeds x' in_v@(_, v)
      | dUPLICATE_VALUES_EVALUATOR = fmap (,in_v) $ claimDeeds (deeds + 1) (annedValueSize' v)
      | otherwise                  = return (deeds, (mkIdentityRenaming [x'], Indirect x'))

    -- We have not yet claimed deeds for the result of this function
    lookupValue :: Heap -> Out Var -> Maybe (In AnnedValue)
    lookupValue (Heap h _) x' = do
        hb <- M.lookup x' h
        case hb of
          Concrete  (rn, anned_e) -> fmap ((rn,) . annee) $ termToValue anned_e
          Unfolding (rn, anned_v) -> Just (rn, annee anned_v)
          _                       -> Nothing
    
    -- Deal with a variable at the top of the stack
    force :: Deeds -> Heap -> Stack -> Tag -> Out Var -> Maybe UnnormalisedState
    force deeds (Heap h ids) k tg x'
      | Just in_v <- lookupValue (Heap h ids) x'
      = do { (deeds, in_v) <- prepareValue deeds x' in_v; unwind deeds (Heap h ids) k tg in_v }
      | otherwise
      = do { Concrete in_e <- M.lookup x' h; return (deeds, Heap (M.delete x' h) ids, Tagged tg (Update x') : k, in_e) }

    -- Deal with a value at the top of the stack
    unwind :: Deeds -> Heap -> Stack -> Tag -> In AnnedValue -> Maybe UnnormalisedState
    unwind deeds h k tg_v in_v = uncons k >>= \(kf, k) -> case tagee kf of
        Apply x2'                 -> apply      (deeds + 1)          h k      in_v x2'
        Scrutinise in_alts        -> scrutinise (deeds + 1)          h k tg_v in_v in_alts
        PrimApply pop in_vs in_es -> primop     deeds       (tag kf) h k tg_v pop in_vs in_v in_es
        Update x'
          | normalising, dUPLICATE_VALUES_EVALUATOR -> Nothing -- If duplicating values, we ensure normalisation by not executing updates
          | otherwise                               -> update deeds h k tg_v x' in_v
      where
        -- When derereferencing an indirection, it is important that the resulting value is not stored anywhere. The reasons are:
        --  1) That would cause allocation to be duplicated if we residualised immediately afterwards, because the value would still be in the heap
        --  2) It would cause a violation of the deeds invariant because *syntax* would be duplicate
        --  3) It feels a bit weird because it might turn phantom stuff into real stuff
        --
        -- Indirections do not change the deeds story much (at all). You have to pay a deed per indirection, which is released
        -- whenever the indirection dies in the process of evaluation (e.g. in the function position of an application). The deeds
        -- that the indirection "points to" are not affected by any of this. The exception is if we *retain* any subcomponent
        -- of the dereferenced thing - in this case we have to be sure to claim some deeds for that subcomponent. For example, if we
        -- dereference to get a lambda in our function application we had better claim deeds for the body.
        dereference :: Heap -> In AnnedValue -> In AnnedValue
        dereference h (rn, Indirect x) | Just (rn', anned_v') <- lookupValue h (safeRename "dereference" rn x) = dereference h (rn', anned_v')
        dereference _ in_v = in_v
    
        apply :: Deeds -> Heap -> Stack -> In AnnedValue -> Out Var -> Maybe UnnormalisedState
        apply deeds h k in_v@(_, v) x2'
          | normalising, not dUPLICATE_VALUES_EVALUATOR, Indirect _ <- v = Nothing -- If not duplicating values, we ensure normalisation by not executing applications to non-explicit-lambdas
          | (rn, Lambda x e_body) <- dereference h in_v = fmap (\deeds -> (deeds, h, k, (insertRenaming x x2' rn, e_body))) $ claimDeeds (deeds + annedValueSize' v) (annedSize e_body)
          | otherwise                                   = Nothing -- Might happen theoretically if we have an unresovable indirection

        scrutinise :: Deeds -> Heap -> Stack -> Tag -> In AnnedValue -> In [AnnedAlt] -> Maybe UnnormalisedState
        scrutinise deeds (Heap h ids) k tg_v (rn_v, v)  (rn_alts, alts)
          | Literal l <- v_deref
          , (alt_e, rest):_ <- [((rn_alts, alt_e), rest) | ((LiteralAlt alt_l, alt_e), rest) <- bagContexts alts, alt_l == l]
          = Just (deeds + annedValueSize' v + annedAltsSize rest, Heap h ids, k, alt_e)
          | Data dc xs <- v_deref
          , (alt_e, rest):_ <- [((insertRenamings (alt_xs `zip` map (rename rn_v_deref) xs) rn_alts, alt_e), rest) | ((DataAlt alt_dc alt_xs, alt_e), rest) <- bagContexts alts, alt_dc == dc]
          = Just (deeds + annedValueSize' v + annedAltsSize rest, Heap h ids, k, alt_e)
          | ((mb_alt_x, alt_e), rest):_ <- [((mb_alt_x, alt_e), rest) | ((DefaultAlt mb_alt_x, alt_e), rest) <- bagContexts alts]
          = Just $ case mb_alt_x of
                     Nothing    -> (deeds + annedValueSize' v + annedAltsSize rest, Heap h                                                               ids,  k, (rn_alts,  alt_e))
                     Just alt_x -> (deeds +                     annedAltsSize rest, Heap (M.insert alt_x' (Concrete (rn_v, annedTerm tg_v $ Value v)) h) ids', k, (rn_alts', alt_e))
                       where (ids', rn_alts', alt_x') = renameBinder ids rn_alts alt_x
                             -- NB: we add the *non-dereferenced* value to the heap in a default branch with variable, because anything else may duplicate allocation
          | otherwise
          = Nothing -- This can legitimately occur, e.g. when supercompiling (if x then (case x of False -> 1) else 2)
          where (rn_v_deref, v_deref) = dereference (Heap h ids) (rn_v, v)

        primop :: Deeds -> Tag -> Heap -> Stack -> Tag -> PrimOp -> [In (Anned AnnedValue)] -> In AnnedValue -> [In AnnedTerm] -> Maybe UnnormalisedState
        primop deeds tg_kf h k _tg_v2 pop [(rn_v1, anned_v1)] (rn_v2, v2) []
          | (_, Literal (Int l1)) <- dereference h (rn_v1, annee anned_v1)
          , (_, Literal (Int l2)) <- dereference h (rn_v2, v2)
          , Just v <- f pop l1 l2
          , let e' = annedTerm tg_kf (Value v)
          , Just deeds <- claimDeeds (deeds + annedSize anned_v1 + annedValueSize' v2 + 1) (annedSize e') -- I don't think this can ever fail
          = Just (deeds, h, k, (emptyRenaming, e'))
          | otherwise
          = Nothing -- Can occur legitimately if some of the arguments of the primop are just indirections to nothing or irreducible (division by zero?)
          where f pop = case pop of Add -> retInt (+); Subtract -> retInt (-);
                                    Multiply -> retInt (*); Divide -> \l1 l2 -> guard (l2 /= 0) >> retInt div l1 l2; Modulo -> retInt mod;
                                    Equal -> retBool (==); LessThan -> retBool (<); LessThanEqual -> retBool (<=)
                retInt  pop l1 l2 = Just $ Literal (Int (pop l1 l2))
                retBool pop l1 l2 = Just $ if pop l1 l2 then Data trueDataCon [] else Data falseDataCon []
        primop deeds tg_kf h k tg_v pop in_vs (rn, v) (in_e:in_es) = Just (deeds, h, Tagged tg_kf (PrimApply pop (in_vs ++ [(rn, annedValue tg_v v)]) in_es) : k, in_e)
        primop _     _     _ _ _    _   _     _       _            = Nothing -- I don't think this can occur legitimately

        update :: Deeds -> Heap -> Stack -> Tag -> Out Var -> In AnnedValue -> Maybe UnnormalisedState
        update deeds (Heap h ids) k tg_v x' (rn, v) = case prepareValue deeds x' in_v of
            Nothing             -> trace (render (text "update-deeds:" <+> pPrint x')) Nothing
            Just (deeds', in_v) ->                                                     Just (deeds', Heap (M.insert x' (Concrete (rn, annedTerm tg_v (Value v))) h) ids, k, second (annedTerm tg_v . Value) in_v)
