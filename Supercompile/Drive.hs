{-# LANGUAGE ViewPatterns, TupleSections, PatternGuards, BangPatterns, Rank2Types #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
module Supercompile.Drive (supercompile) where

import Supercompile.Match
import Supercompile.Residualise
import Supercompile.Split

import Core.FreeVars
import Core.Renaming
import Core.Syntax
import Core.Tag

import Evaluator.Evaluate
import Evaluator.FreeVars
import Evaluator.Syntax

import Size.Deeds

import Termination.TagBag
import Termination.TagGraph
import Termination.Terminate

import Name
import Renaming
import StaticFlags
import Utilities

import qualified Data.Map as M
import Data.Ord
import qualified Data.Set as S
import Data.Tree


supercompile :: Term -> Term
supercompile e = traceRender ("all input FVs", input_fvs) $ fVedTermToTerm $ runScpM input_fvs $ fmap snd $ (case tAG_COLLECTION of TagBag -> sc (undefined :: TagBag) emptyHistory; TagGraph -> sc (undefined :: TagGraph) emptyHistory) (deeds, state)
  where input_fvs = annedTermFreeVars anned_e
        state = (Heap M.empty reduceIdSupply, [], (mkIdentityRenaming $ S.toList input_fvs, anned_e))
        anned_e = toAnnedTerm e
        
        deeds = mkDeeds (bLOAT_FACTOR - 1) (t, pPrint . rb)
        
        (t, rb) = extractDeeds (\f e -> let (ts, rb) = f (annee e)
                                        in (Node (annedTag e) ts, \(Node unc ts') -> Counted unc (rb ts'))) anned_e
        
        extractDeeds :: (forall a b.    (a        -> ([Tree Tag], [Tree Int] -> b))
                                     -> Anned a   -> (Tree Tag,   Tree Int   -> Counted b))
                     -> AnnedTerm -> (Tree Tag, Tree Int -> CountedTerm)
        extractDeeds rec = term
          where 
            var = rec var'
            var' x = ([], \[] -> x)
            
            term = rec term'
            term' e = case e of
              Var x              -> ([], \[] -> Var x)
              Value (Lambda x e) -> ([t], \[t'] -> Value (Lambda x (rb t')))
                where (t, rb) = term e
              Value (Data dc xs) -> ([], \[] -> Value (Data dc xs))
              Value (Literal l)  -> ([], \[] -> Value (Literal l))
              App e x            -> ([t1, t2], \[t1', t2'] -> App (rb1 t1') (rb2 t2'))
                where (t1, rb1) = term e
                      (t2, rb2) = var x
              PrimOp pop es      -> (ts, \ts' -> PrimOp pop (zipWith ($) rbs ts'))
                where (ts, rbs) = unzip (map term es)
              Case e (unzip -> (alt_cons, alt_es)) -> (t : ts, \(t':ts') -> Case (rb t') (alt_cons `zip` zipWith ($) rbs ts'))
                where (t, rb)   = term e
                      (ts, rbs) = unzip (map term alt_es)
              LetRec (unzip -> (xs, es)) e         -> (t : ts, \(t':ts') -> LetRec (xs `zip` zipWith ($) rbs ts') (rb t'))
                where (t, rb)   = term e
                      (ts, rbs) = unzip (map term es)


--
-- == Bounded multi-step reduction ==
--

{-# SPECIALISE reduce :: TagBag -> (Deeds, State) -> (Deeds, State) #-}
{-# SPECIALISE reduce :: TagGraph -> (Deeds, State) -> (Deeds, State) #-}
reduce :: TagCollection tc => tc -> (Deeds, State) -> (Deeds, State)
reduce tc (deeds, state) = (deeds', state')
  where
    (_, deeds', state') = go emptyHistory S.empty (emptyLosers, deeds, state)
      
    go hist lives (losers, deeds, state)
      -- | traceRender ("reduce.go", residualiseState state) False = undefined
      | not eVALUATE_PRIMOPS, (_, _, (_, annee -> PrimOp _ _)) <- state = (losers, deeds, state)
      | otherwise = fromMaybe (losers, deeds, state) $ either id id $ do
          hist' <- case terminate hist (stateTags state `asTypeOf` tc) of
                      _ | intermediate state  -> Right hist
                      -- _ | traceRender ("reduce.go (non-intermediate)", residualiseState state) False -> undefined
                      Continue mk_hist        -> Right (mk_hist (deeds, state))
                      Stop _   (deeds, state) -> trace "reduce-stop" $ Left (guard rEDUCE_ROLLBACK >> return (losers, deeds, state)) -- FIXME: generalise?
          Right $ fmap (go hist' lives) $ step (go hist') lives (losers, deeds, state)
    
    intermediate :: State -> Bool
    intermediate (_, _, (_, annee -> Var _)) = False
    intermediate _ = True


--
-- == The drive loop ==
--

data Promise = P {
    fun        :: Var,       -- Name assigned in output program
    abstracted :: [Out Var], -- Abstracted over these variables
    lexical    :: [Out Var], -- Refers to these variables lexically (i.e. not via a lambda)
    meaning    :: State      -- Minimum adequate term
  }

-- Note [Which h functions to residualise in withStatics]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Imagine we have driven to this situation:
--
--  let map = ...
--  in ...
--
-- With these "h" functions floating out:
--
--  h1 = \fvs1 -> ... map ...
--  h2 = \fvs2 -> let map = ...
--                in ... h1 ...
--
-- Previously, what withStatics did was residualise those floating "h" function that have lexical
-- free variables that intersect with the set of statics (which is just {map} in this case).
--
-- However, this is insufficient in this example, because we built a map binding locally within h2
-- and so it does not occur as a lexical FV of h2. However, h2 refers to h1 (which does have map as a
-- lexical FV) so what is going to happen is that h2 will float out past h1 and we will get a variable
-- out of scope error at the reference to h1.
--
-- There are two solutions:
--  1) When pushing heap bindings down into several different contexts, give them different names in each
--     context. Then we will end up in a situation like:
--
--  let map1 = ...
--  in ...
--
--  h1 = \fvs1 -> ... map1 ...
--  h2 = \fvs2 -> let map2 = ...
--                in ... h1 ...
--
-- Now map1 will be a lexical FV of h1 and all will be well.
--
--  2) Make the h functions that get called into lexical FVs of the h function making the call, and then
--     compute the least fixed point of the statics set in withStatics, residualising h functions that are
--     referred to only by other h functions.
--
--  This solution is rather elegant because it falls out naturally if I make the FreeVars set returned by the
--  supercompiler exactly equal to the free variables of the term returned (previously I excluded h functions
--  from the set, but *included* lexical FVs of any h functions called). This simplifies the description of the
--  supercompiler but also means that in the future I might just be able to return a TermWithFVs or something --
--  memoising the FVs on the term structure itself.

instance MonadStatics ScpM where
    withStatics orig_xs mx = bindFloats (any (`S.member` xs) . lexical) $ ScpM $ \e s k -> unScpM mx (e { statics = statics e `S.union` xs }) s (\(!res) s -> traceRender ("withStatics", xs) $ k res s)
      where xs = if lOCAL_TIEBACKS then orig_xs else S.empty -- NB: it's important we still use bindFloats in (not lOCAL_TIEBACKS) because h functions are static

-- NB: be careful of this subtle problem:
--
--  let h6 = D[e1]
--      residual = ...
--      h7 = D[... let residual = ...
--                 in Just residual]
--  in ...
--
-- If we first drive e1 and create a fulfilment for the h6 promise, then when driving h7 we will eventually come across a residual binding for the
-- "residual" variable. If we aren't careful, we will notice that "residual" is a FV of the h6 fulfilment and residualise it deep within h7. But
-- what if the body of the outermost let drove to something referring to h6? We have a FV - disaster!
--
-- The right thing to do is to make sure that fulfilments created in different "branches" of the process tree aren't eligible for early binding in
-- that manner, but we still want to tie back to them if possible. The bindFloats function achieves this by carefully shuffling information between the
-- fulfilments and promises parts of the monadic-carried state.
bindFloats :: (Promise -> Bool) -> ScpM a -> ScpM (Out [(Var, FVedTerm)], a)
bindFloats p mx = ScpM $ \e s k -> unScpM mx (e { promises = map fst (fulfilments s) ++ promises e }) (s { fulfilments = [] }) (\x _e (s'@(ScpState { fulfilments = (partition (p . fst) -> (fs_now, fs_later)) })) -> traceRender ("bindFloats", map (fun . fst) fs_now, map (fun . fst) fs_later) $ k (sortBy (comparing ((read :: String -> Int) . drop 1 . name_string . fst)) [(fun p, lambdas (abstracted p) e') | (p, e') <- fs_now], x) e (s' { fulfilments = fs_later ++ fulfilments s }))

getStatics :: ScpM FreeVars
getStatics = ScpM $ \e s k -> k (statics e) e s

freshHName :: ScpM Var
freshHName = ScpM $ \e s k -> k (expectHead "freshHName" (names s)) e (s { names = tail (names s) })

getPromises :: ScpM [Promise]
getPromises = ScpM $ \e s k -> k (promises e ++ map fst (fulfilments s)) e s

promise :: Promise -> ScpM (a, Out FVedTerm) -> ScpM (a, Out FVedTerm)
promise p opt = ScpM $ \e s k -> traceRender ("promise", fun p, abstracted p, lexical p) $ unScpM (mx p) (e { promises = p : promises e, statics = S.insert (fun p) (statics e) }) s k
  where
    mx p = do
      (a, e') <- opt
      ScpM $ \e s k -> k () e (s { fulfilments = (p, e') : fulfilments s })
      
      let fvs' = fvedTermFreeVars e' in fmap (S.fromList . ((abstracted p ++ lexical p) ++) . map fun) getPromises >>= \fvs -> assertRender ("sc: FVs", fun p, fvs' S.\\ fvs, fvs) (fvs' `S.isSubsetOf` fvs) $ return ()
      
      return (a, fun p `varApps` abstracted p)


data ScpEnv = ScpEnv {
    statics  :: Statics, -- NB: we do not abstract the h functions over these variables. This helps typechecking and gives GHC a chance to inline the definitions.
    promises :: [Promise]
  }

data ScpState = ScpState {
    names       :: [Var],
    fulfilments :: [(Promise, Out FVedTerm)]
  }

newtype ScpM a = ScpM { unScpM :: ScpEnv -> ScpState -> (a -> ScpEnv -> ScpState -> Out FVedTerm) -> Out FVedTerm }

instance Functor ScpM where
    fmap = liftM

instance Monad ScpM where
    return x = ScpM $ \e s k -> k x e s
    (!mx) >>= fxmy = ScpM $ \e s k -> unScpM mx e s (\x _e s -> unScpM (fxmy x) e s k)

runScpM :: FreeVars -> ScpM (Out FVedTerm) -> Out FVedTerm
runScpM input_fvs me = unScpM (bindFloats (\_ -> True) me) init_e init_s (\(xes', e') _ _ -> letRecSmart xes' e')
  where
    init_e = ScpEnv { statics = input_fvs, promises = [] }
    init_s = ScpState { names = map (\i -> name $ 'h' : show (i :: Int)) [0..], fulfilments = [] }

catchScpM :: ((c -> ScpM b) -> ScpM a) -- ^ Action to try: supplies a function than can be called to "raise an exception". Raising an exception restores the original ScpEnv and ScpState
          -> (c -> ScpM a)             -- ^ Handler deferred to if an exception is raised
          -> ScpM a                    -- ^ Result from either the main action or the handler
catchScpM f_try f_abort = ScpM $ \e s k -> unScpM (f_try (\c -> ScpM $ \_ _ _ -> unScpM (f_abort c) e s k)) e s k


newtype Rollback tc = RB { rollbackWith :: (GrowingTags, History tc (Maybe (Rollback tc))) -> ScpM (Deeds, Out FVedTerm) }

{-# SPECIALISE sc' :: TagBag   -> History TagBag   (Maybe (Rollback TagBag))   -> (Deeds, State) -> ScpM (Deeds, Out FVedTerm) #-}
{-# SPECIALISE sc' :: TagGraph -> History TagGraph (Maybe (Rollback TagGraph)) -> (Deeds, State) -> ScpM (Deeds, Out FVedTerm) #-}
sc, sc' :: TagCollection tc => tc -> History tc (Maybe (Rollback tc)) -> (Deeds, State) -> ScpM (Deeds, Out FVedTerm)
sc  tc hist = memo (sc' tc hist)
sc' tc hist (deeds, state) = (check . Just . RB) `catchScpM` \(gtgs, hist') -> stop gtgs (hist `forgetFutureHistory` hist') -- NB: I want to use the original history here, but I think doing so leads to non-term as it contains rollbacks from "below us" (try DigitsOfE2)
  where
    check mb_rb = case terminate hist (stateTags state `asTypeOf` tc) of
                    Continue mk_hist -> continue (mk_hist mb_rb)
                    Stop gtgs mb_rb  -> maybe (stop gtgs hist) (`rollbackWith` (gtgs, hist)) $ guard sC_ROLLBACK >> mb_rb
    stop gtgs hist = trace "sc-stop" $ split (traceRender ("gtgs", gtgs) $ (gtgs `isTagGrowing`)) (sc tc hist)            (deeds, state)
    continue  hist =                   split (const False)                                        (sc tc hist) ((\res@(_, state') -> traceRender ("reduce end", residualiseState state') res) $
                                                                                                                reduce tc (deeds, state)) -- TODO: experiment with doing admissability-generalisation on reduced terms. My suspicion is that it won't help, though (such terms are already stuck or non-stuck but loopy: throwing stuff away does not necessarily remove loopiness).

memo :: ((Deeds, State) -> ScpM (Deeds, Out FVedTerm))
     ->  (Deeds, State) -> ScpM (Deeds, Out FVedTerm)
memo opt (deeds, state) = do
    statics <- getStatics
    ps <- getPromises
    case [ (fun p, (releaseStateDeed deeds state, fun p `varApps` tb_dynamic_vs))
         | p <- ps
         , Just rn_lr <- [-- (\res -> if isNothing res then traceRender ("no match:", fun p) res else res) $
                           match (meaning p) state]
         , let rn_fvs = map (safeRename ("tieback: FVs " ++ pPrintRender (fun p)) rn_lr) -- NB: If tb contains a dead PureHeap binding (hopefully impossible) then it may have a free variable that I can't rename, so "rename" will cause an error. Not observed in practice yet.
               tb_dynamic_vs = rn_fvs (abstracted p)
               tb_static_vs  = rn_fvs (lexical p)
          -- Check that all of the things that were dynamic last time are dynamic this time.
          -- This is an issue of *performance* and *typeability*. If we omit this check, the generated code may
          -- be harder for GHC to chew on because we will apply static variables to dynamic positions in the tieback.
          -- FIXME: rejecting tieback on this basis leads to crappy code generation (since we immediately whistle).
         , (\res -> if res then True else traceRender ("memo: rejected by dynamics", statics, tb_dynamic_vs) False) $
           all (`S.notMember` statics) tb_dynamic_vs
          -- Check that all of the things that were static last time are static this time *and refer to exactly the same thing*.
          -- This is an issue of *correctness*. If we omit this check, we may tie back to a version of the function where a FV
          -- actually referred to a different let binding than that which we intend to refer tos.
         , (\res -> if res then True else traceRender ("memo: rejected by statics", lexical p, tb_static_vs) False) $
           and $ zipWith (\x x' -> x' == x && x' `S.member` statics) (lexical p) tb_static_vs
         , traceRender ("memo'", statics, stateFreeVars state, rn_lr, (fun p, lexical p, abstracted p)) True
         ] of
      (_x, res):_ -> {- traceRender ("tieback", residualiseState state, fst res) $ -} do
        traceRenderM ("=sc", _x, residualiseState state, deeds, res)
        return res
      [] -> {- traceRender ("new drive", residualiseState state) $ -} do
        let vs = stateFreeVars state
            (static_vs_list, dynamic_vs_list) = partition (`S.member` statics) (S.toList vs)
    
        -- NB: promises are lexically scoped because they may refer to FVs
        x <- freshHName
        promise P { fun = x, abstracted = dynamic_vs_list, lexical = static_vs_list, meaning = state } $ do
            traceRenderM (">sc", x, residualiseState state, deeds)
            res <- opt (deeds, state)
            traceRenderM ("<sc", x, residualiseState state, res)
            return res

traceRenderM :: (Pretty a, Monad m) => a -> m ()
--traceRenderM x mx = fmap length history >>= \indent -> traceRender (nest indent (pPrint x)) mx
traceRenderM x = traceRender (pPrint x) (return ())
