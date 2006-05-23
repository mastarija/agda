{-# OPTIONS -cpp -fglasgow-exts #-}

{-| TODO: take care of hidden arguments -}
module TypeChecking.Reduce where

import Control.Monad.State
import Control.Monad.Reader
import Data.List as List
import Data.Map as Map
import Data.Generics
import Data.FunctorM

import Syntax.Common
import Syntax.Internal
import Syntax.Internal.Walk

import TypeChecking.Monad
import TypeChecking.Monad.Context
import TypeChecking.Substitute

#ifndef __HADDOCK__
import {-# SOURCE #-} TypeChecking.Patterns.Match
#endif

import Utils.Monad

import TypeChecking.Monad.Debug
__debug = debug

#include "../undefined.h"

normalise :: Data a => a -> TCM a
normalise = walk (mkM redType `extM` redTerm `extM` redSort)
    where
	redTerm :: Term -> WalkT TCM Term
	redTerm = lift . lift . reduce

	redType :: Type -> WalkT TCM Type
	redType = lift . lift . reduce

	redSort :: Sort -> WalkT TCM Sort
	redSort = lift . lift . reduce

-- | Instantiate something.
--   Results in an open meta variable or a non meta.
--   Doesn't do any reduction, and preserves blocking tags (when blocking meta
--   is uninstantiated).
class Instantiate t where
    instantiate :: t -> TCM t

instance Instantiate Term where
    instantiate t@(MetaV x args) =
	do  mi <- mvInstantiation <$> lookupMeta x
	    case mi of
		InstV a -> instantiate $ a `apply` args
		Open	-> return t
		_	-> __IMPOSSIBLE__
    instantiate v@(BlockedV (Blocked x u)) =
	do  mi <- mvInstantiation <$> lookupMeta x
	    case mi of
		InstV _ -> instantiate u
		Open	-> return v
		_	-> __IMPOSSIBLE__
    instantiate t = return t

instance Instantiate Type where
    instantiate t@(MetaT x args) =
	do  mi <- mvInstantiation <$> lookupMeta x
	    case mi of
		InstT t' -> instantiate $ t' `apply` args
		Open	 -> return t
		_	 -> __IMPOSSIBLE__
    instantiate t = return t

instance Instantiate Sort where
    instantiate s@(MetaS x) =
	do  mi <- mvInstantiation <$> lookupMeta x
	    case mi of
		InstS s' -> instantiate s'
		Open	 -> return s
		_	 -> __IMPOSSIBLE__
    instantiate s = return s

instance Instantiate t => Instantiate (Arg t) where
    instantiate = fmapM instantiate

instance Instantiate t => Instantiate [t] where
    instantiate = mapM instantiate

instance (Instantiate a, Instantiate b) => Instantiate (a,b) where
    instantiate (x,y) = (,) <$> instantiate x <*> instantiate y

--
-- Reduction to weak head normal form.
--
class Reduce t where
    reduce :: t -> TCM t

instance Reduce Type where
    reduce a =
	do  b <- instantiate a
	    case b of
		El t s -> El <$> reduce t <*> reduce s
		Sort s -> Sort <$> reduce s
		_      -> return b

instance Reduce Sort where
    reduce s =
	do  s <- instantiate s
	    case s of
		Suc s'	  -> sSuc <$> reduce s'
		Lub s1 s2 -> sLub <$> reduce s1 <*> reduce s2
		_	  -> return s

instance Reduce t => Reduce [t] where
    reduce = mapM reduce

instance Reduce t => Reduce (Arg t) where
    reduce = fmapM reduce

instance (Reduce a, Reduce b) => Reduce (a,b) where
    reduce (x,y) = (,) <$> reduce x <*> reduce y

instance Reduce Term where
    reduce v =
	do  v <- instantiate v
	    case v of
		Lam (Abs _ v') (Arg h arg:args) ->
		    do  a <- reduce arg
			reduce $ subst a v' `apply` args
		MetaV x args -> MetaV x <$> reduce args
		Def f args   -> reduceDef (Def f []) f args
		Con c args   -> reduceDef (Con c []) c args
						-- constructors can have definitions
						-- when they come from an instantiated module
						-- (change this)
		BlockedV _ -> return v
		Lit _	   -> return v
		Var x args -> Var x <$> reduce args
		Lam _ []   -> return v
	where

	    reduceDef v0 f args =
		do  def <- defClauses <$> getConstInfo f
		    case def of
			[] -> return v -- no definition for head
			cls@(Clause ps _ : _) -> 
			    if length ps == length args then
				do  ev <- appDef v0 cls args
				    either return reduce ev
			    else if length ps < length args then
				let (args1,args2) = splitAt (length ps) args 
				in do   ev <- appDef v0 cls args1
					case ev of
					    Left v	-> return $ v `apply` args2
					    Right v	-> reduce $ v `apply` args2
			    else return v -- partial application

	    -- Apply a defined function to it's arguments.
	    --   The original term is the first argument applied to the third.
	    --	 'Left' means no match and 'Right' means match.
	    appDef :: Term -> [Clause] -> Args -> TCM (Either Term Term)
	    appDef v cls args = goCls cls args where
		goCls [] _ = return $ Left v -- no clause matched, can happen with parameter arguments
		goCls (cl@(Clause pats body) : cls) args =
		    do	(m, args) <- matchPatterns pats args
			case m of
			    Yes args'	      -> Right <$> app args' body
			    No		      -> goCls cls args
			    DontKnow Nothing  -> return $ Left $ v `apply` args
			    DontKnow (Just m) -> return $ Left $ blocked m $ v `apply` args
		app [] (Body v') = return v'
		app (arg : args) (Bind (Abs _ body)) = app args $ subst arg body -- CBN
		app _ _ = __IMPOSSIBLE__

