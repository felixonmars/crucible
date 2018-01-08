------------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.CFG.Generator
-- Description      : Provides a monadic interface for constructing Crucible
--                    control flow graphs.
-- Copyright        : (c) Galois, Inc 2014
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module provides a monadic interface for constructing control flow
-- graph expressions.  The goal is to make it easy to convert languages
-- into CFGs.
--
-- The CFGs generated by this interface are similar to, but not quite the
-- same as, the CFGs defined in Lang.Crucible.Core.  The the module
-- Lang.Crucible.SSAConversion contains code that converts the CFGs produced
-- by this interface into Core CFGs in SSA form.
------------------------------------------------------------------------
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Lang.Crucible.CFG.Generator
  ( -- * Generator
    Generator
  , getPosition
  , setPosition
  , withPosition
  , readGlobal
  , writeGlobal
  , newRef
  , newEmptyRef
  , readRef
  , writeRef
  , dropRef
  , newReg
  , newUnassignedReg
  , newUnassignedReg'
  , readReg
  , assignReg
  , modifyReg
  , modifyRegM
  , extensionStmt
  , forceEvaluation
  , addPrintStmt
  , call
  , mkAtom
  , recordCFG
  , FunctionDef
  , defineFunction
    -- * Low-level terminal expressions.
  , End
  , endNow
  , newLabel
  , newLambdaLabel
  , newLambdaLabel'
  , endCurrentBlock
  , defineBlock
  , defineLambdaBlock
  , resume
  , resume_
  , branch
    -- * Combinators
  , jump
  , jumpToLambda
  , returnFromFunction
  , reportError
  , whenCond
  , unlessCond
  , assertExpr
  , ifte
  , ifte_
  , ifteM
  , MatchMaybe(..)
  , caseMaybe
  , caseMaybe_
  , fromJustExpr
  , assertedJustExpr
  , while
  -- * Re-exports
  , Ctx.Ctx(..)
  , Position
  , module Lang.Crucible.CFG.Reg
  ) where

import           Control.Lens hiding (Index)
import           Control.Monad.State.Strict
import qualified Data.Foldable as Fold
import           Data.Maybe
import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableFC
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import           Lang.Crucible.CFG.Core (AnyCFG(..), GlobalVar(..))
import           Lang.Crucible.CFG.Expr(App(..), IsSyntaxExtension)
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.CFG.Reg
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.ProgramLoc
import           Lang.Crucible.Types
import           Lang.Crucible.Utils.MonadST
import           Lang.Crucible.Utils.StateContT

------------------------------------------------------------------------
-- CurrentBlockState

-- | A sequence of statements.
type StmtSeq ext s = Seq (Posd (Stmt ext s))

-- | Information about block being generated in Generator.
data CurrentBlockState ext s
   = CBS { -- | Identifier for current block
           cbsBlockID       :: !(BlockID s)
         , cbsInputValues   :: !(ValueSet s)
         , _cbsStmts        :: !(StmtSeq ext s)
         }

initCurrentBlockState :: ValueSet s -> BlockID s -> CurrentBlockState ext s
initCurrentBlockState inputs block_id =
  CBS { cbsBlockID     = block_id
      , cbsInputValues = inputs
      , _cbsStmts      = Seq.empty
      }

-- | Statements translated so far in this block.
cbsStmts :: Simple Lens (CurrentBlockState ext s) (StmtSeq ext s)
cbsStmts = lens _cbsStmts (\s v -> s { _cbsStmts = v })

------------------------------------------------------------------------
-- GeneratorState

-- | State for translating within a basic block.
data GeneratorState ext s (t :: * -> *) ret
   = GS { _gsBlocks    :: !(Seq (Block ext s ret))
        , _gsNextLabel :: !Int
        , _gsNextValue :: !Int
        , _gsCurrent   :: !(Maybe (CurrentBlockState ext s))
        , _gsPosition  :: !Position
        , _gsState     :: !(t s)
        , _seenFunctions :: ![AnyCFG ext]
        }

-- | List of previously processed blocks.
gsBlocks :: Simple Lens (GeneratorState ext s t ret) (Seq (Block ext s ret))
gsBlocks = lens _gsBlocks (\s v -> s { _gsBlocks = v })

-- | Index of next label.
gsNextLabel :: Simple Lens (GeneratorState ext s t ret) Int
gsNextLabel = lens _gsNextLabel (\s v -> s { _gsNextLabel = v })

-- | Index used for register and atom identifiers.
gsNextValue :: Simple Lens (GeneratorState ext s t ret) Int
gsNextValue = lens _gsNextValue (\s v -> s { _gsNextValue = v })

-- | Information about current block.
gsCurrent :: Simple Lens (GeneratorState ext s t ret) (Maybe (CurrentBlockState ext s))
gsCurrent = lens _gsCurrent (\s v -> s { _gsCurrent = v })

-- | Current Statements translated so far in this block.
gsPosition :: Simple Lens (GeneratorState ext s t ret) Position
gsPosition = lens _gsPosition (\s v -> s { _gsPosition = v })

-- | State for current block.  This gets reset between blocks.
gsState :: Simple Lens (GeneratorState ext s t ret) (t s)
gsState = lens _gsState (\s v -> s { _gsState = v })

-- | List of functions seen by current generator.
seenFunctions :: Simple Lens (GeneratorState ext s t r) [AnyCFG ext]
seenFunctions = lens _seenFunctions (\s v -> s { _seenFunctions = v })

checkCurrentUnassigned :: MonadState (GeneratorState ext s t ret) m => m ()
checkCurrentUnassigned = do
  mc <- use gsCurrent
  when (isJust mc) $ do
    error "Current block is still assigned."

------------------------------------------------------------------------
-- Generator

-- | A generator is used for constructing a CFG from a sequence of
-- monadic actions.
--
-- It wraps the 'ST' monad to allow clients to create references, and
-- has a phantom type parameter to prevent constructs from different
-- CFGs from being mixed.
--
-- The 'ext' parameter indicates the syntax extension.
-- The 'h' parameter is the parameter for the underlying ST monad.
-- The 's' parameter is the phantom parameter for CFGs.
-- The 't' parameter is the parameterized type that allows user-defined
-- state.  It is reset at each block.
-- The 'ret' parameter is the return type of the CFG.
-- The 'a' parameter is the value returned by the monad.
newtype Generator ext h s t ret a
      = Generator { unGenerator :: StateContT (GeneratorState ext s t ret)
                                              (GeneratorState ext s t ret)
                                              (ST h)
                                              a
                  }
  deriving ( Functor
           , Applicative
           , MonadST h
           )

instance Monad (Generator ext h s t ret) where
  return  = Generator . return
  x >>= f = Generator (unGenerator x >>= unGenerator . f)
  fail msg = Generator $ do
     p <- use gsPosition
     fail $ "at " ++ show p ++ ": " ++ msg

instance MonadState (t s) (Generator ext h s t ret) where
  get = Generator $ use gsState
  put v = Generator $ gsState .= v

-- | Get the current position.
getPosition :: Generator ext h s t ret Position
getPosition = Generator $ use gsPosition

-- | Set the current position.
setPosition :: Position -> Generator ext h s t ret ()
setPosition p = Generator $ gsPosition .= p

-- | Set the current position temporarily, and reset it afterwards.
withPosition :: Position
             -> Generator ext h s t ret a
             -> Generator ext h s t ret a
withPosition p m = do
  old_pos <- getPosition
  setPosition p
  v <- m
  setPosition old_pos
  return v

freshValueIndex :: MonadState (GeneratorState ext s t ret) m => m Int
freshValueIndex = do
  n <- use gsNextValue
  gsNextValue .= n+1
  return n

newUnassignedReg'' :: MonadState (GeneratorState ext s r ret) m => TypeRepr tp -> m (Reg s tp)
newUnassignedReg'' tp = do
  p <- use gsPosition
  n <- freshValueIndex
  return $! Reg { regPosition = p
                , regId = n
                , typeOfReg = tp
                }

addStmt :: MonadState (GeneratorState ext s t ret) m => Stmt ext s -> m ()
addStmt s = do
  p <- use gsPosition
  Just cbs <- use gsCurrent
  let ps = Posd p s
  seq ps $ do
  let cbs' = cbs & cbsStmts %~ (Seq.|> ps)
  seq cbs' $ gsCurrent .= Just cbs'

freshAtom :: IsSyntaxExtension ext => AtomValue ext s tp -> Generator ext h s t ret (Atom s tp)
freshAtom av = Generator $ do
  p <- use gsPosition
  i <- freshValueIndex
  let atom = Atom { atomPosition = p
                  , atomId = i
                  , atomSource = Assigned
                  , typeOfAtom = typeOfAtomValue av
                  }
  addStmt $ DefineAtom atom av
  return atom

-- | Create an atom equivalent to the given expression if it is
-- not already an atom.
mkAtom :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Atom s tp)
mkAtom (AtomExpr a)   = return a
mkAtom (App a)        = freshAtom . EvalApp =<< traverseFC mkAtom a

-- | Generate a new virtual register with the given initial value.
newReg :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Reg s tp)
newReg e = do
  a <- mkAtom e
  Generator $ do
    r <- newUnassignedReg'' (typeOfAtom a)
    addStmt (SetReg r a)
    return r

-- | Read a global variable
readGlobal :: IsSyntaxExtension ext => GlobalVar tp -> Generator ext h s t ret (Expr ext s tp)
readGlobal v = AtomExpr <$> freshAtom (ReadGlobal v)

-- | Write to a global variable
writeGlobal :: IsSyntaxExtension ext => GlobalVar tp -> Expr ext s tp -> Generator ext h s t ret ()
writeGlobal v e = do
  a <-  mkAtom e
  Generator $ addStmt $ WriteGlobal v a

-- | Read the current value of a reference cell.
readRef :: IsSyntaxExtension ext => Expr ext s (ReferenceType tp) -> Generator ext h s t ret (Expr ext s tp)
readRef ref = do
  r <- mkAtom ref
  AtomExpr <$> freshAtom (ReadRef r)

-- | Write the given value into the reference cell.
writeRef :: IsSyntaxExtension ext => Expr ext s (ReferenceType tp) -> Expr ext s tp -> Generator ext h s t ret ()
writeRef ref val = do
  r <- mkAtom ref
  v <- mkAtom val
  Generator $ addStmt (WriteRef r v)

-- | Deallocate the given reference cell, returning it to an uninialized state.
--   The reference cell can still be used; subsequent writes will succeed,
--   and reads will succeed if some value is written first.
dropRef :: IsSyntaxExtension ext => Expr ext s (ReferenceType tp) -> Generator ext h s t ret ()
dropRef ref = do
  r <- mkAtom ref
  Generator $ addStmt (DropRef r)

-- | Generate a new reference cell with the given initial contents.
newRef :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Expr ext s (ReferenceType tp))
newRef val = do
  v <- mkAtom val
  AtomExpr <$> freshAtom (NewRef v)

-- | Generate a new empty reference cell.  If an unassigned reference is later
--   read, it will generate a runtime error.
newEmptyRef :: IsSyntaxExtension ext => TypeRepr tp -> Generator ext h s t ret (Expr ext s (ReferenceType tp))
newEmptyRef tp =
  AtomExpr <$> freshAtom (NewEmptyRef tp)

-- | Produce a new virtual register without giving it an initial value.
--   NOTE! If you fail to initialize this register with a subsequent
--   call to @assignReg@, errors will arise during SSA conversion.
newUnassignedReg' :: TypeRepr tp -> End ext h s t ret (Reg s tp)
newUnassignedReg' tp = End $ newUnassignedReg'' tp

-- | Produce a new virtual register without giving it an initial value.
--   NOTE! If you fail to initialize this register with a subsequent
--   call to @assignReg@, errors will arise during SSA conversion.
newUnassignedReg :: TypeRepr tp -> Generator ext h s t ret (Reg s tp)
newUnassignedReg tp = Generator $ newUnassignedReg'' tp

-- | Get value of register at current time.
readReg :: IsSyntaxExtension ext => Reg s tp -> Generator ext h s t ret (Expr ext s tp)
readReg r = AtomExpr <$> freshAtom (ReadReg r)

-- | Update the value of a register.
assignReg :: IsSyntaxExtension ext => Reg s tp -> Expr ext s tp -> Generator ext h s t ret ()
assignReg r e = do
  a <-  mkAtom e
  Generator $ addStmt $ SetReg r a

-- | Modify the value of a register.
modifyReg :: IsSyntaxExtension ext => Reg s tp -> (Expr ext s tp -> Expr ext s tp) -> Generator ext h s t ret ()
modifyReg r f = do
  v <- readReg r
  assignReg r $! f v

-- | Modify the value of a register.
modifyRegM :: IsSyntaxExtension ext
           => Reg s tp
           -> (Expr ext s tp -> Generator ext h s t ret (Expr ext s tp))
           -> Generator ext h s t ret ()
modifyRegM r f = do
  v <- readReg r
  v' <- f v
  assignReg r v'

-- | Add a statement to print a value.
addPrintStmt :: IsSyntaxExtension ext => Expr ext s StringType -> Generator ext h s t ret ()
addPrintStmt e = do
  e_a <- mkAtom e
  Generator $ addStmt (Print e_a)

-- | Add an assert stmt to the generator.
assertExpr :: IsSyntaxExtension ext => Expr ext s BoolType -> Expr ext s StringType -> Generator ext h s t ret ()
assertExpr b e = do
  b_a <- mkAtom b
  e_a <- mkAtom e
  Generator $ addStmt $ Assert b_a e_a

-- | Stash the given CFG away for later retrieval.  This is primarily
--   used when translating inner and anonymous functions in the
--   context of an outer function.
recordCFG :: AnyCFG ext -> Generator ext h s t ret ()
recordCFG g = Generator $ seenFunctions %= (g:)

------------------------------------------------------------------------
-- End

-- | A low-level interface for defining transitions between basic-blocks.
--
-- The 'ext' parameter indicates the syntax extension.
-- The 'h' parameter is the ST index used for 'ST h'
-- The 's' parameter is part of the CFG.
-- The 't' is parameter is for the user-defined state.
-- The 'ret' parameter is the return type for the CFG.
newtype End ext h s t ret a = End { unEnd :: StateT (GeneratorState ext s t ret) (ST h) a }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadST h
           )

instance MonadState (t s) (End ext h s t ret) where
  get = End (use gsState)
  put x = End (gsState .= x)

-- | End the current translation.
endNow :: ((a -> End ext h s t ret ())
          -> End ext h s t ret ())
       -> Generator ext h s t ret a
endNow m = Generator $ StateContT $ \c ts -> do
  let f v = End $ do
        s <- get
        put =<< liftST (c v s)
  execStateT (unEnd (m f)) ts

-- | Create a new block label
newLabel :: End ext h s t ret (Label s)
newLabel = End $ do
  idx <- use gsNextLabel
  gsNextLabel .= idx + 1
  return (Label idx)

-- | Create a new lambda label
newLambdaLabel :: KnownRepr TypeRepr tp => End ext h s t ret (LambdaLabel s tp)
newLambdaLabel = newLambdaLabel' knownRepr

newLambdaLabel' :: TypeRepr tp -> End ext h s t ret (LambdaLabel s tp)
newLambdaLabel' tpr = End $ do
  p <- use gsPosition
  idx <- use gsNextLabel
  gsNextLabel .= idx + 1

  i <- freshValueIndex

  let lbl = LambdaLabel idx a
      a = Atom { atomPosition = p
               , atomId = i
               , atomSource = LambdaArg lbl
               , typeOfAtom = tpr
               }
  return $! lbl

-- | Define the current block by defining the position and
-- final statement.  This returns the user state after the
-- block is finished.
endCurrentBlock :: IsSyntaxExtension ext
                => TermStmt s ret
                -> End ext h s t ret ()
endCurrentBlock term = End $ do
  gs <- get
  let p = gs^.gsPosition
  let Just cbs = gs^.gsCurrent
  -- Clear current state.
  gsCurrent .= Nothing
  -- Define block
  let b = mkBlock (cbsBlockID cbs) (cbsInputValues cbs) (cbs^.cbsStmts) (Posd p term)
  -- Store block
  seq b $ do
  gsBlocks %= (Seq.|> b)

-- | Resume execution by jumping to a label.
resume_  :: Label s -- ^ Label to jump to.
         -> (() -> End ext h s t ret ())
            -- ^ Continuation to run.
         -> End ext h s t ret ()
resume_ lbl c = End $ do
  checkCurrentUnassigned
  gsCurrent .= Just (initCurrentBlockState Set.empty (LabelID lbl))
  unEnd $ c ()

-- | Resume execution by jumping to a lambda label
resume :: LambdaLabel s r
          -- ^ Label to jump to.
       -> (Expr ext s r -> End ext h s t ret ())
          -- ^ Continuation to run.
       -> End ext h s t ret ()
resume lbl c = End $ do
  let block_id = LambdaID lbl
  checkCurrentUnassigned
  gsCurrent .= Just (initCurrentBlockState Set.empty block_id)
  unEnd $ c (AtomExpr (lambdaAtom lbl))

defineSomeBlock :: BlockID s
                -> Generator ext h s t ret ()
                -> End ext h s t ret ()
defineSomeBlock l next = End $ do
  gs <- get
  let gs_next = gs & gsCurrent .~ Just (initCurrentBlockState Set.empty l)
  let c_next _ gs' =
        let p' = gs'^.gsPosition
         in error $ "Block at " ++ show p' ++ " ended without terminating."
  gs' <- liftST $ runStateContT (unGenerator next) c_next gs_next
  -- Reset current block and state.
  put $ gs' & gsCurrent  .~ gs^.gsCurrent
            & gsPosition .~ gs^.gsPosition
            & gsState    .~ gs^.gsState

-- | Define a block with an ordinary label.
defineBlock :: Label s
            -> Generator ext h s t ret ()
            -> End ext h s t ret ()
defineBlock l next =
  defineSomeBlock (LabelID l) next

-- | Define a block that has a lambda label
defineLambdaBlock :: LambdaLabel s i
                  -> (Expr ext s i -> Generator ext h s t ret ())
                  -> End ext h s t ret ()
defineLambdaBlock l next = do
  let block_id = LambdaID l
  defineSomeBlock block_id $ next (AtomExpr (lambdaAtom l))

------------------------------------------------------------------------
-- Generator interface

-- | Evaluate an expression, so that it can be more efficiently evaluated later.
forceEvaluation :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Expr ext s tp)
forceEvaluation e = AtomExpr <$> mkAtom e

-- | Add a statement from the syntax extension to the current basic block.
extensionStmt ::
   IsSyntaxExtension ext =>
   StmtExtension ext (Expr ext s) tp ->
   Generator ext h s t ret (Expr ext s tp)
extensionStmt stmt = do
   stmt' <- traverseFC mkAtom stmt
   AtomExpr <$> freshAtom (EvalExt stmt')

-- | Call a function.
call :: IsSyntaxExtension ext
        => Expr ext s (FunctionHandleType args ret)
        -> Assignment (Expr ext s) args
        -> Generator ext h s t r (Expr ext s ret)
call h args = AtomExpr <$> call' h args

-- | Call a function.
call' :: IsSyntaxExtension ext
        => Expr ext s (FunctionHandleType args ret)
        -> Assignment (Expr ext s) args
        -> Generator ext h s t r (Atom s ret)
call' h args = do
  case exprType h of
    FunctionHandleRepr _ retType -> do
      h_a <- mkAtom h
      args_a <- traverseFC mkAtom args
      freshAtom $ Call h_a args_a retType

-- | Jump to given label.
jump :: IsSyntaxExtension ext => Label s -> Generator ext h s t ret a
jump l = do
  endNow $ \_ -> do
    endCurrentBlock (Jump l)

-- | Jump to label with output.
jumpToLambda :: IsSyntaxExtension ext => LambdaLabel s tp -> Expr ext s tp -> Generator ext h s t ret a
jumpToLambda lbl v = do
  v_a <- mkAtom v
  endNow $ \_ -> do
    endCurrentBlock (Output lbl v_a)

-- | Branch between blocks, returns label of this block.
branch :: IsSyntaxExtension ext
       => Expr ext s BoolType
       -> Label s
       -> Label s
       -> Generator ext h s t ret a
branch (App (Not e)) x_id y_id = do
  branch e y_id x_id
branch e x_id y_id = do
  a <- mkAtom e
  endNow $ \_ -> do
    endCurrentBlock (Br a x_id y_id)

------------------------------------------------------------------------
-- Combinators

-- | Return from this function.
returnFromFunction :: IsSyntaxExtension ext => Expr ext s ret -> Generator ext h s t ret a
returnFromFunction e = do
  e_a <- mkAtom e
  endNow $ \_ -> do
    endCurrentBlock (Return e_a)

-- | Report error message.
reportError :: IsSyntaxExtension ext => Expr ext s StringType -> Generator ext h s t ret a
reportError e = do
  e_a <- mkAtom e
  endNow $ \_ -> do
    endCurrentBlock (ErrorStmt e_a)

-- | If-then-else. The first action if the 'true' branch, the second of the
-- 'false' branch. See 'Br' in "Lang.Crucible.Core".
ifte :: (IsSyntaxExtension ext, KnownRepr TypeRepr tp)
     => Expr ext s BoolType
     -> Generator ext h s t ret (Expr ext s tp)
     -> Generator ext h s t ret (Expr ext s tp)
     -> Generator ext h s t ret (Expr ext s tp)
ifte e x y = do
  e_a <- mkAtom e
  endNow $ \c -> do
    x_id <- newLabel
    y_id <- newLabel
    c_id <- newLambdaLabel

    endCurrentBlock (Br e_a x_id y_id)
    defineBlock x_id $ x >>= jumpToLambda c_id
    defineBlock y_id $ y >>= jumpToLambda c_id
    resume c_id c

ifteM :: (IsSyntaxExtension ext, KnownRepr TypeRepr tp)
     => Generator ext h s t ret (Expr ext s BoolType)
     -> Generator ext h s t ret (Expr ext s tp)
     -> Generator ext h s t ret (Expr ext s tp)
     -> Generator ext h s t ret (Expr ext s tp)
ifteM em x y = do { m <- em; ifte m x y }

ifte_ :: IsSyntaxExtension ext
      => Expr ext s BoolType
      -> Generator ext h s t ret ()
      -> Generator ext h s t ret ()
      -> Generator ext h s t ret ()
ifte_ e x y = do
  e_a <- mkAtom e
  endNow $ \c -> do
    x_id <- newLabel
    y_id <- newLabel
    c_id <- newLabel

    endCurrentBlock (Br e_a x_id y_id)
    defineBlock x_id $ x >> jump c_id
    defineBlock y_id $ y >> jump c_id
    resume_ c_id c

-- | Run a computation when a condition is false.
whenCond :: IsSyntaxExtension ext
         => Expr ext s BoolType
         -> Generator ext h s t ret ()
         -> Generator ext h s t ret ()
whenCond e x = do
  e_a <- mkAtom e
  endNow $ \c -> do
    t_id <- newLabel
    c_id <- newLabel

    endCurrentBlock $! Br e_a t_id c_id
    defineBlock t_id $ x >> jump c_id
    resume_ c_id c

-- | Run a computation when a condition is false.
unlessCond :: IsSyntaxExtension ext
           => Expr ext s BoolType
           -> Generator ext h s t ret ()
           -> Generator ext h s t ret ()
unlessCond e x = do
  e_a <- mkAtom e
  endNow $ \c -> do
    f_id <- newLabel
    c_id <- newLabel

    endCurrentBlock  $ Br e_a c_id f_id
    defineBlock f_id $ x >> jump c_id
    resume_ c_id c

data MatchMaybe j r
   = MatchMaybe
   { onJust :: j -> r
   , onNothing :: r
   }

caseMaybe :: IsSyntaxExtension ext
          => Expr ext s (MaybeType tp)
          -> TypeRepr r
          -> MatchMaybe (Expr ext s tp) (Generator ext h s t ret (Expr ext s r))
          -> Generator ext h s t ret (Expr ext s r)
caseMaybe v retType cases = do
  v_a <- mkAtom v
  let etp = case exprType v of
              MaybeRepr etp' -> etp'
  endNow $ \c -> do
    j_id <- newLambdaLabel' etp
    n_id <- newLabel
    c_id <- newLambdaLabel' retType

    endCurrentBlock $ MaybeBranch etp v_a j_id n_id
    defineLambdaBlock j_id $ onJust cases >=> jumpToLambda c_id
    defineBlock       n_id $ onNothing cases >>= jumpToLambda c_id
    resume c_id c

caseMaybe_ :: IsSyntaxExtension ext
           => Expr ext s (MaybeType tp)
           -> MatchMaybe (Expr ext s tp) (Generator ext h s t ret ())
           -> Generator ext h s t ret ()
caseMaybe_ v cases = do
  v_a <- mkAtom v
  let etp = case exprType v of
              MaybeRepr etp' -> etp'
  endNow $ \c -> do
    j_id <- newLambdaLabel' etp
    n_id <- newLabel
    c_id <- newLabel

    endCurrentBlock $ MaybeBranch etp v_a j_id n_id
    defineLambdaBlock j_id $ \e -> onJust cases e >> jump c_id
    defineBlock       n_id $ onNothing cases >> jump c_id
    resume_ c_id c

fromJustExpr :: IsSyntaxExtension ext
             => Expr ext s (MaybeType tp)
             -> Expr ext s StringType
             -> Generator ext h s t ret (Expr ext s tp)
fromJustExpr e msg = do
  let etp = case exprType e of
              MaybeRepr etp' -> etp'
  caseMaybe e etp MatchMaybe
    { onJust = return
    , onNothing = reportError msg
    }

-- | This asserts that the value in the expression is a just value, and
-- returns the underlying value.
assertedJustExpr :: IsSyntaxExtension ext
                 => Expr ext s (MaybeType tp)
                 -> Expr ext s StringType
                 -> Generator ext h s t ret (Expr ext s tp)
assertedJustExpr e msg =
  case exprType e of
    MaybeRepr tp ->
      forceEvaluation $! App (FromJustValue tp e msg)

while :: IsSyntaxExtension ext
      => (Position, Generator ext h s t ret (Expr ext s BoolType))
      -> (Position, Generator ext h s t ret ())
      -> Generator ext h s t ret ()
while (pcond,cond) (pbody,body) = do
  endNow $ \cont -> do
    cond_lbl <- newLabel
    loop_lbl <- newLabel
    exit_lbl <- newLabel

    p <- End $ use gsPosition
    endCurrentBlock (Jump cond_lbl)

    End $ gsPosition .= pcond
    defineBlock cond_lbl $ do
      b <- cond
      branch b loop_lbl exit_lbl

    End $ gsPosition .= pbody
    defineBlock loop_lbl $ do
      body
      jump cond_lbl
    -- Reset position
    End $ gsPosition .= p
    resume_ exit_lbl cont

------------------------------------------------------------------------
-- CFG

cfgFromGenerator :: FnHandle init ret
                 -> GeneratorState ext s t ret
                 -> CFG ext s init ret
cfgFromGenerator h s =
  CFG { cfgHandle = h
      , cfgBlocks = Fold.toList (s^.gsBlocks)
      }

-- | Given the arguments, this returns the initial state, and an action for
-- computing the return value
type FunctionDef ext h t init ret
   = forall s
   . Assignment (Atom s) init
     -> (t s, Generator ext h s t ret (Expr ext s ret))

-- | The main API for generating CFGs for a Crucible function.
--
--   The given @FunctionDef@ action is run to generate a registerized
--   CFG.  The return value of this action is the generated CFG, and a
--   list of CFGs for any other auxiliary function definitions
--   generated along the way (e.g., for anonymous or inner functions).
defineFunction :: IsSyntaxExtension ext
               => Position                 -- ^ Source position for the function
               -> FnHandle init ret        -- ^ Handle for the generated function
               -> FunctionDef ext h t init ret -- ^ Generator action and initial state
               -> ST h (SomeCFG ext init ret, [AnyCFG ext]) -- ^ Generated CFG and inner function definitions
defineFunction p h f = seq h $ do
  let argTypes = handleArgTypes h
  let c () = return

  let inputs = mkInputAtoms p argTypes
  let inputSet = Set.fromList (toListFC (Some . AtomValue) inputs)
  let (init_state, action) = f $! inputs
  let cbs = initCurrentBlockState inputSet (LabelID (Label 0))
  let ts = GS { _gsBlocks = Seq.empty
              , _gsNextLabel = 1
              , _gsNextValue  = Ctx.sizeInt (Ctx.size argTypes)
              , _gsCurrent = Just cbs
              , _gsPosition = p
              , _gsState = init_state
              , _seenFunctions = []
              }
  let go = returnFromFunction =<< action
  ts' <- runStateContT (unGenerator go) c $! ts
  return (SomeCFG (cfgFromGenerator h ts'), ts'^.seenFunctions)
