{-# LANGUAGE ViewPatterns, TupleSections, PatternGuards, BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
module Supercompile.Drive (supercompile) where

import Supercompile.Match
import Supercompile.Residualise
import Supercompile.Split

import Core.FreeVars
import Core.Renaming
import Core.Syntax

import Evaluator.Evaluate
import Evaluator.FreeVars
import Evaluator.Syntax

import Size.Deeds

import Termination.Terminate

import Name
import Renaming
import StaticFlags
import Utilities

import Control.Monad.Fix

import qualified Data.Map as M
import Data.Ord
import qualified Data.Set as S
import Data.Tree


supercompile :: Term -> Term
supercompile e = traceRender ("all input FVs", input_fvs) $ runScpM input_fvs $ fmap thd3 $ sc [] (deeds, state)
  where input_fvs = termFreeVars e
        state = (Heap M.empty reduceIdSupply, [], (mkIdentityRenaming $ S.toList input_fvs, tagged_e))
        tagged_e = tagTerm tagIdSupply e
        
        (t, rb) = extractDeeds tagged_e
        deeds = mkDeeds (bLOAT_FACTOR - 1) (t, pPrint . rb)
        extractDeeds (Tagged tg e) = -- traceRender ("extractDeeds", rb (fmap (fmap (const 1)) ts)) $
                                     (Node tg ts, \(Node unc ts') -> Counted unc (rb ts'))
          where (ts, rb) = extractDeeds' e
        extractDeeds' e = case e of
          Var x              -> ([], \[] -> Var x)
          Value (Lambda x e) -> ([t], \[t'] -> Value (Lambda x (rb t')))
            where (t, rb) = extractDeeds e
          Value (Data dc xs) -> ([], \[] -> Value (Data dc xs))
          Value (Literal l)  -> ([], \[] -> Value (Literal l))
          App e x            -> ([t1, t2], \[t1', t2'] -> App (rb1 t1') (rb2 t2'))
            where (t1, rb1) = extractDeeds e
                  (t2, rb2) = (Node (tag x) [], \(Node unc []) -> Counted unc (tagee x))
          PrimOp pop es      -> (ts, \ts' -> PrimOp pop (zipWith ($) rbs ts'))
            where (ts, rbs) = unzip (map extractDeeds es)
          Case e (unzip -> (alt_cons, alt_es)) -> (t : ts, \(t':ts') -> Case (rb t') (alt_cons `zip` zipWith ($) rbs ts'))
            where (t, rb)   = extractDeeds e
                  (ts, rbs) = unzip (map extractDeeds alt_es)
          LetRec (unzip -> (xs, es)) e         -> (t : ts, \(t':ts') -> LetRec (xs `zip` zipWith ($) rbs ts') (rb t'))
            where (t, rb)   = extractDeeds e
                  (ts, rbs) = unzip (map extractDeeds es)


--
-- == Termination ==
--

-- Other functions:
--  Termination.Terminate.terminate

-- This family of functions is the whole reason that I have to thread Tag information throughout the rest of the code:

stateTagBag :: State -> TagBag
stateTagBag (Heap h _, k, (_, e)) = pureHeapTagBag h `plusTagBag` stackTagBag k `plusTagBag` taggedTermTagBag e

pureHeapTagBag :: PureHeap -> TagBag
pureHeapTagBag = plusTagBags . map (taggedTagBag 5 . snd) . M.elems

stackTagBag :: Stack -> TagBag
stackTagBag = plusTagBags . map (tagTagBag 3) . concatMap stackFrameTags

taggedTermTagBag :: TaggedTerm -> TagBag
taggedTermTagBag = taggedTagBag 2

taggedTagBag :: Int -> Tagged a -> TagBag
taggedTagBag cls = tagTagBag cls . tag

tagTagBag :: Int -> Tag -> TagBag
tagTagBag cls = mkTagBag . return . injectTag cls


--
-- == Bounded multi-step reduction ==
--

reduce :: (Deeds, State) -> (Deeds, State)
reduce = go emptyHistory S.empty
  where
    go hist lives (deeds, state)
      | traceRender ("reduce.go", deeds, residualiseState state) False = undefined
      | not eVALUATE_PRIMOPS, (_, _, (_, Tagged _ (PrimOp _ _))) <- state = (deeds, state)
      | otherwise = fromMaybe (deeds, state) $ do
          hist' <- case terminate hist (stateTagBag state) of
                      _ | intermediate state -> Just hist
                      Continue hist'         -> Just hist'
                      Stop                   -> Nothing
          fmap (go hist' lives) $ step (go hist') lives (deeds, state)
    
    intermediate :: State -> Bool
    intermediate (_, _, (_, Tagged _ (Var _))) = False
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
    withStatics xs_before mx = bindFloats (\p -> any (`S.member` xs) (lexical p)) $ ScpM $ \e s -> (\(!res) -> traceRender ("withStatics", xs) res) $ unScpM mx (e { statics = statics e `S.union` xs }) s
      where xs = if lOCAL_TIEBACKS then xs_before else S.empty -- NB: we still need to deal with h functions themselves being statics even if we don't have local h functions

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
-- fulfulmints and promises parts of the monadic-carried state.
bindFloats :: (Promise -> Bool) -> ScpM a -> ScpM ([(Out Var, Out Term)], FreeVars, a)
bindFloats p mx = ScpM $ \e s -> case unScpM mx (e { promises = map fst (fulfilments s) ++ promises e }) (s { fulfilments = [] }) of (s'@(ScpState { fulfilments = (partitionFloats -> (fs_now, fs_later)) }), x) -> traceRender ("bindFloats", map (fun . fst) fs_now, map (fun . fst) fs_later) $ (s' { fulfilments = fs_later ++ fulfilments s }, (sortBy (comparing ((read :: String -> Int) . drop 1 . name_string . fst)) [(fun p, lambdas (abstracted p) e') | (p, e') <- fs_now], S.unions [S.fromList (lexical p) | (p, _) <- fs_now], x))
  where
    partitionFloats :: [(Promise, Out Term)] -> ([(Promise, Out Term)], [(Promise, Out Term)]) -- Returns things to bind here and things to keep floating, respectively
    partitionFloats promises = go (partition (p . fst) promises)
      where
        -- This fixed point ensures that we residualise any floats that refer to other floats that we have residualised
        go (stick, float) | null stick' = (stick, float)
                          | otherwise   = go (stick ++ stick', float')
          where (stick', float') = partition (\(floating_promise, _) -> any (\stick_x' -> stick_x' `elem` lexical floating_promise) (map (fun . fst) stick)) float

getStatics :: ScpM FreeVars
getStatics = ScpM $ \e s -> (s, statics e)

freshHName :: ScpM Var
freshHName = ScpM $ \_ s -> (s { names = tail (names s) }, expectHead "freshHName" (names s))

getPromises :: ScpM [Promise]
getPromises = ScpM $ \e s -> (s, promises e ++ map fst (fulfilments s))

promise :: Promise -> ScpM (a, FreeVars, Out Term) -> ScpM (a, FreeVars, Out Term)
promise p opt = ScpM $ \e s -> traceRender ("promise", fun p, abstracted p, lexical p) $ unScpM (mx p) e { promises = p : promises e, statics = S.insert (fun p) (statics e) } s
  where
    mx p = do
      (a, fvs', e') <- opt
      let vs = S.fromList (abstracted p ++ lexical p) in assertRender ("sc: FVs", fun p, fvs' S.\\ vs, vs) (fvs' `S.isSubsetOf` vs) $ return ()
      ScpM $ \_ s -> (s { fulfilments = (p, e') : fulfilments s }, ())
      return (a, S.insert (fun p) (S.fromList (abstracted p)), fun p `varApps` abstracted p)


data ScpEnv = ScpEnv {
    statics  :: Statics, -- NB: we do not abstract the h functions over these variables. This helps typechecking and gives GHC a chance to inline the definitions.
    promises :: [Promise]
  }

data ScpState = ScpState {
    names       :: [Var],
    fulfilments :: [(Promise, Out Term)]
  }

newtype ScpM a = ScpM { unScpM :: ScpEnv -> ScpState -> (ScpState, a) }

instance Functor ScpM where
    fmap = liftM

instance Monad ScpM where
    return x = ScpM $ \_ s -> (s, x)
    (!mx) >>= fxmy = ScpM $ \e s -> case unScpM mx e s of (s, x) -> unScpM (fxmy x) e s

instance MonadFix ScpM where
    mfix fmx = ScpM $ \e s -> let (s', x) = unScpM (fmx x) e s in (s', x)

runScpM :: FreeVars -> ScpM (Out Term) -> Out Term
runScpM input_fvs me = letRec hes e'
  where
    (hes, _, e') = snd $ unScpM (bindFloats (\_ -> True) me) init_e init_s
      
    init_e = ScpEnv { statics = input_fvs, promises = [] }
    init_s = ScpState { names = map (\i -> name $ "h" ++ show (i :: Int)) [0..], fulfilments = [] }


sc, sc' :: History -> (Deeds, State) -> ScpM (Deeds, FreeVars, Out Term)
sc  hist = memo (sc' hist)
sc' hist (deeds, state) = case terminate hist (stateTagBag state) of
    Stop           -> trace "stop" $ split (sc hist)          (deeds, state)
    Continue hist' ->                split (sc hist') (reduce (deeds, state))


memo :: ((Deeds, State) -> ScpM (Deeds, FreeVars, Out Term))
     ->  (Deeds, State) -> ScpM (Deeds, FreeVars, Out Term)
memo opt (deeds, state) = do
    statics <- getStatics
    ps <- getPromises
    case [ (fun p, (releaseStateDeed deeds state, S.insert (fun p) $ S.fromList (tb_dynamic_vs), fun p `varApps` tb_dynamic_vs))
         | p <- ps
         , Just rn_lr <- [match (meaning p) state]
         , let rn_fvs = map (safeRename ("tieback: FVs " ++ pPrintRender (fun p)) rn_lr) -- NB: If tb contains a dead PureHeap binding (hopefully impossible) then it may have a free variable that I can't rename, so "rename" will cause an error. Not observed in practice yet.
               tb_dynamic_vs = rn_fvs (abstracted p)
               tb_static_vs  = rn_fvs (lexical p)
          -- Check that all of the things that were dynamic last time are dynamic this time
         , all (\x' -> x' `S.notMember` statics) tb_dynamic_vs
          -- Check that all of the things that were static last time are static this time *and refer to exactly the same thing*
         , and $ zipWith (\x x' -> x' == x && x' `S.member` statics) (lexical p) tb_static_vs -- FIXME: lexical should include transitive lexical vars?
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
        promise (P { fun = x, abstracted = dynamic_vs_list, lexical = static_vs_list, meaning = state }) $ do
            traceRenderM (">sc", x, residualiseState state, deeds)
            res <- opt (deeds, state)
            traceRenderM ("<sc", x, residualiseState state, res)
            return res

traceRenderM :: (Pretty a, Monad m) => a -> m ()
--traceRenderM x mx = fmap length history >>= \indent -> traceRender (nest indent (pPrint x)) mx
traceRenderM x = traceRender (pPrint x) (return ())
