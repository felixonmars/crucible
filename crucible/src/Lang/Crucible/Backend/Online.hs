------------------------------------------------------------------------
-- |
-- Module      : Lang.Crucible.Backend.Online
-- Description : A solver backend that maintains a persistent connection
-- Copyright   : (c) Galois, Inc 2015-2016
-- License     : BSD3
-- Maintainer  : Joe Hendrix <jhendrix@galois.com>
-- Stability   : provisional
--
-- The online backend maintains an open connection to an SMT solver
-- that is used to prune unsatisfiable execution traces during simulation.
-- At every symbolic branch point, the SMT solver is queried to determine
-- if one or both symbolic branches are unsatisfiable.
-- Only branches with satisfiable branch conditions are explored.
--
-- The online backend also allows override definitions access to a
-- persistent SMT solver connection.  This can be useful for some
-- kinds of algorithms that benefit from quickly performing many
-- small solver queries in a tight interaction loop.
------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lang.Crucible.Backend.Online
  ( -- * OnlineBackend
    OnlineBackend
  , withOnlineBackend
  , initialOnlineBackendState
  , checkSatisfiable
  , checkSatisfiableWithModel
  , withSolverProcess
  , withSolverProcess'
  , resetSolverProcess
  , UnsatFeatures(..)
  , unsatFeaturesToProblemFeatures
    -- ** Configuration options
  , solverInteractionFile
  , onlineBackendOptions
    -- ** Branch satisfiability
  , BranchResult(..)
  , considerSatisfiability
    -- ** Yices
  , YicesOnlineBackend
  , withYicesOnlineBackend
    -- ** Z3
  , Z3OnlineBackend
  , withZ3OnlineBackend
    -- ** CVC4
  , CVC4OnlineBackend
  , withCVC4OnlineBackend
    -- ** STP
  , STPOnlineBackend
  , withSTPOnlineBackend
    -- * OnlineBackendState
  , OnlineBackendState(..)
    -- * Re-exports
  , B.FloatMode
  , B.FloatModeRepr(..)
  , B.FloatIEEE
  , B.FloatUninterpreted
  , B.FloatReal
  , B.Flags
  ) where


import           Control.Lens
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Data.Bits
import           Data.Data (Data)
import           Data.Foldable
import           Data.IORef
import           Data.Parameterized.Nonce
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           System.IO
import qualified Data.Text as Text
import qualified Text.PrettyPrint.ANSI.Leijen as PP

import           What4.Config
import qualified What4.Expr.Builder as B
import           What4.Interface
import           What4.ProblemFeatures
import           What4.ProgramLoc
import           What4.Protocol.Online
import           What4.Protocol.SMTWriter as SMT
import           What4.Protocol.SMTLib2 as SMT2
import           What4.SatResult
import qualified What4.Solver.CVC4 as CVC4
import qualified What4.Solver.STP as STP
import qualified What4.Solver.Yices as Yices
import qualified What4.Solver.Z3 as Z3

import           Lang.Crucible.Backend
import           Lang.Crucible.Backend.AssumptionStack as AS
import qualified Lang.Crucible.Backend.ProofGoals as PG
import           Lang.Crucible.Simulator.SimError

data UnsatFeatures
  = NoUnsatFeatures
     -- ^ Do not compute unsat cores or assumptions
  | ProduceUnsatCores
     -- ^ Enable named assumptions and unsat-core computations
  | ProduceUnsatAssumptions
     -- ^ Enable check-with-assumptions commands and unsat-assumptions computations

unsatFeaturesToProblemFeatures :: UnsatFeatures -> ProblemFeatures
unsatFeaturesToProblemFeatures x =
  case x of
    NoUnsatFeatures -> noFeatures
    ProduceUnsatCores -> useUnsatCores
    ProduceUnsatAssumptions -> useUnsatAssumptions

solverInteractionFile :: ConfigOption (BaseStringType Unicode)
solverInteractionFile = configOption knownRepr "solverInteractionFile"

onlineBackendOptions :: [ConfigDesc]
onlineBackendOptions =
  [ mkOpt
      solverInteractionFile
      stringOptSty
      (Just (PP.text "File to echo solver commands and responses for debugging purposes"))
      Nothing
  ]


-- | Get the connection for sending commands to the solver.
withSolverConn ::
  OnlineSolver scope solver =>
  OnlineBackend scope solver fs ->
  (WriterConn scope solver -> IO a) ->
  IO a
withSolverConn sym k = withSolverProcess sym (k . solverConn)

--------------------------------------------------------------------------------
type OnlineBackend scope solver fs =
                        B.ExprBuilder scope (OnlineBackendState solver) fs


type YicesOnlineBackend scope fs = OnlineBackend scope (Yices.Connection scope) fs

-- | Do something with a Yices online backend.
--   The backend is only valid in the continuation.
--
--   The Yices configuration options will be automatically
--   installed into the backend configuration object.
--
--   n.b. the explicit forall allows the fs to be expressed as the
--   first argument so that it can be dictated easily from the caller.
--   Example:
--
--   > withYicesOnlineBackend FloatRealRepr ng f'
withYicesOnlineBackend :: forall fm scope m a . (MonadIO m, MonadMask m) =>
                       (B.FloatModeRepr fm)
                       -> NonceGenerator IO scope
                       -> UnsatFeatures
                       -> (YicesOnlineBackend scope (B.Flags fm) -> m a)
                       -> m a
withYicesOnlineBackend fm gen unsatFeat action =
  let feat = Yices.yicesDefaultFeatures .|. unsatFeaturesToProblemFeatures unsatFeat in
  withOnlineBackend fm gen feat $ \sym ->
    do liftIO $ extendConfig Yices.yicesOptions (getConfiguration sym)
       action sym

type Z3OnlineBackend scope fs = OnlineBackend scope (SMT2.Writer Z3.Z3) fs

-- | Do something with a Z3 online backend.
--   The backend is only valid in the continuation.
--
--   The Z3 configuration options will be automatically
--   installed into the backend configuration object.
--
--   n.b. the explicit forall allows the fs to be expressed as the
--   first argument so that it can be dictated easily from the caller.
--   Example:
--
--   > withz3OnlineBackend FloatRealRepr ng f'
withZ3OnlineBackend :: forall fm scope m a . (MonadIO m, MonadMask m) =>
                    (B.FloatModeRepr fm)
                    -> NonceGenerator IO scope
                    -> UnsatFeatures
                    -> (Z3OnlineBackend scope (B.Flags fm) -> m a)
                    -> m a
withZ3OnlineBackend fm gen unsatFeat action =
  let feat = (SMT2.defaultFeatures Z3.Z3 .|. unsatFeaturesToProblemFeatures unsatFeat) in
  withOnlineBackend fm gen feat $ \sym ->
    do liftIO $ extendConfig Z3.z3Options (getConfiguration sym)
       action sym

type CVC4OnlineBackend scope fs = OnlineBackend scope (SMT2.Writer CVC4.CVC4) fs

-- | Do something with a CVC4 online backend.
--   The backend is only valid in the continuation.
--
--   The CVC4 configuration options will be automatically
--   installed into the backend configuration object.
--
--   n.b. the explicit forall allows the fs to be expressed as the
--   first argument so that it can be dictated easily from the caller.
--   Example:
--
--   > withCVC4OnlineBackend FloatRealRepr ng f'
withCVC4OnlineBackend :: forall fm scope m a . (MonadIO m, MonadMask m) =>
                      (B.FloatModeRepr fm)
                      -> NonceGenerator IO scope
                      -> UnsatFeatures
                      -> (CVC4OnlineBackend scope (B.Flags fm) -> m a)
                      -> m a
withCVC4OnlineBackend fm gen unsatFeat action =
  let feat = (SMT2.defaultFeatures CVC4.CVC4 .|. unsatFeaturesToProblemFeatures unsatFeat) in
  withOnlineBackend fm gen feat $ \sym -> do
    liftIO $ extendConfig CVC4.cvc4Options (getConfiguration sym)
    action sym

type STPOnlineBackend scope fs = OnlineBackend scope (SMT2.Writer STP.STP) fs

-- | Do something with a STP online backend.
--   The backend is only valid in the continuation.
--
--   The STO configuration options will be automatically
--   installed into the backend configuration object.
--
--   n.b. the explicit forall allows the fs to be expressed as the
--   first argument so that it can be dictated easily from the caller.
--   Example:
--
--   > withSTPOnlineBackend FloatRealRepr ng f'
withSTPOnlineBackend :: forall fm scope m a . (MonadIO m, MonadMask m) =>
                     (B.FloatModeRepr fm)
                     -> NonceGenerator IO scope
                     -> (STPOnlineBackend scope (B.Flags fm) -> m a)
                     -> m a
withSTPOnlineBackend fm gen action =
  withOnlineBackend fm gen (SMT2.defaultFeatures STP.STP) $ \sym -> do
    liftIO $ extendConfig STP.stpOptions (getConfiguration sym)
    action sym

------------------------------------------------------------------------
-- OnlineBackendState: implementation details.

-- | Is the solver running or not?
data SolverState scope solver =
    SolverNotStarted
  | SolverStarted (SolverProcess scope solver) (Maybe Handle)

-- | This represents the state of the backend along a given execution.
-- It contains the current assertions and program location.
data OnlineBackendState solver scope = OnlineBackendState
  { assumptionStack ::
      !(AssumptionStack (B.BoolExpr scope) AssumptionReason SimError)
      -- ^ Number of times we have pushed
  , solverProc :: !(IORef (SolverState scope solver))
    -- ^ The solver process, if any.
  , currentFeatures :: !(IORef ProblemFeatures)
  }

-- | Returns an initial execution state.
initialOnlineBackendState ::
  NonceGenerator IO scope ->
  ProblemFeatures ->
  IO (OnlineBackendState solver scope)
initialOnlineBackendState gen feats =
  do stk <- initAssumptionStack gen
     procref <- newIORef SolverNotStarted
     featref <- newIORef feats
     return $! OnlineBackendState
                 { assumptionStack = stk
                 , solverProc = procref
                 , currentFeatures = featref
                 }

getAssumptionStack ::
  OnlineBackend scope solver fs ->
  IO (AssumptionStack (B.BoolExpr scope) AssumptionReason SimError)
getAssumptionStack sym = assumptionStack <$> readIORef (B.sbStateManager sym)


-- | Shutdown any currently-active solver process.
--   A fresh solver process will be started on the
--   next call to `getSolverProcess`.
resetSolverProcess ::
  OnlineSolver scope solver =>
  OnlineBackend scope solver fs ->
  IO ()
resetSolverProcess sym = do
  do st <- readIORef (B.sbStateManager sym)
     mproc <- readIORef (solverProc st)
     case mproc of
       -- Nothing to do
       SolverNotStarted -> return ()
       SolverStarted p auxh ->
         do _ <- shutdownSolverProcess p
            maybe (return ()) hClose auxh
            writeIORef (solverProc st) SolverNotStarted

-- | Get the solver process.
--   Starts the solver, if that hasn't happened already.
withSolverProcess' ::
  OnlineSolver scope solver =>
  (B.ExprBuilder scope s fs -> IO (OnlineBackendState solver scope)) ->
  B.ExprBuilder scope s fs ->
  (SolverProcess scope solver -> IO a) ->
  IO a
withSolverProcess' getSolver sym action = do
  st <- getSolver sym
  let stk = assumptionStack st
  mproc <- readIORef (solverProc st)
  auxOutSetting <- getOptionSetting solverInteractionFile (getConfiguration sym)
  (p, auxh) <-
       case mproc of
         SolverStarted p auxh -> return (p, auxh)
         SolverNotStarted ->
           do feats <- readIORef (currentFeatures st)
              auxh <-
                getMaybeOpt auxOutSetting >>= \case
                  Nothing -> return Nothing
                  Just fn
                    | Text.null fn -> return Nothing
                    | otherwise    -> Just <$> openFile (Text.unpack fn) WriteMode
              p <- startSolverProcess feats auxh sym
              -- set up the solver in the same assumption state as specified
              -- by the current assumption stack
              (do frms <- AS.allAssumptionFrames stk
                  restoreAssumptionFrames p frms
                ) `onException`
                (killSolver p `finally` maybe (return ()) hClose auxh)
              writeIORef (solverProc st) (SolverStarted p auxh)
              return (p, auxh)

  case solverErrorBehavior p of
    ContinueOnError ->
      action p
    ImmediateExit ->
      onException
        (action p)
        ((killSolver p)
          `finally`
         (maybe (return ()) hClose auxh)
          `finally`
         (writeIORef (solverProc st) SolverNotStarted))

-- | Get the solver process, specialized to @OnlineBackend@.
withSolverProcess ::
  OnlineSolver scope solver =>
  OnlineBackend scope solver fs ->
  (SolverProcess scope solver -> IO a) ->
  IO a
withSolverProcess = withSolverProcess' (\sym -> readIORef (B.sbStateManager sym))

-- | Result of attempting to branch on a predicate.
data BranchResult
     -- | The both branches of the predicate might be satisfiable
     --   (although satisfiablility of either branch is not guaranteed).
   = IndeterminateBranchResult

     -- | Commit to the branch where the given predicate is equal to
     --   the returned boolean.  The opposite branch is unsatisfiable
     --   (although the given branch is not necessarily satisfiable).
   | NoBranch !Bool

     -- | The context before considering the given predicate was already
     --   unsatisfiable.
   | UnsatisfiableContext
   deriving (Data, Eq, Generic, Ord, Typeable)


restoreAssumptionFrames ::
  (OnlineSolver scope solver) =>
  SolverProcess scope solver ->
  AssumptionFrames (LabeledPred (B.BoolExpr scope) AssumptionReason) ->
  IO ()
restoreAssumptionFrames proc (AssumptionFrames base frms) =
  do -- assume the base-level assumptions
     mapM_ (SMT.assume (solverConn proc) . view labeledPred) (toList base)

     -- populate the pushed frames
     forM_ (map snd $ toList frms) $ \frm ->
      do push proc
         mapM_ (SMT.assume (solverConn proc) . view labeledPred) (toList frm)

considerSatisfiability ::
  (OnlineSolver scope solver) =>
  OnlineBackend scope solver fs ->
  Maybe ProgramLoc ->
  B.BoolExpr scope ->
  IO BranchResult
considerSatisfiability sym mbPloc p =
  withSolverProcess sym $ \proc ->
   do pnot <- notPred sym p
      let locDesc = case mbPloc of
            Just ploc -> show (plSourceLoc ploc)
            Nothing -> "(unknown location)"
      let rsn = "branch sat: " ++ locDesc
      p_res <- checkSatisfiable proc rsn p
      pnot_res <- checkSatisfiable proc rsn pnot
      case (p_res, pnot_res) of
        (Unsat{}, Unsat{}) -> return UnsatisfiableContext
        (_      , Unsat{}) -> return (NoBranch True)
        (Unsat{}, _      ) -> return (NoBranch False)
        _                  -> return IndeterminateBranchResult

-- | Do something with an online backend.
--   The backend is only valid in the continuation.
--
--   Configuration options are not automatically installed
--   by this operation.
withOnlineBackend ::
  (OnlineSolver scope solver, MonadIO m, MonadMask m) =>
  B.FloatModeRepr fm ->
  NonceGenerator IO scope ->
  ProblemFeatures ->
  (OnlineBackend scope solver (B.Flags fm) -> m a) ->
  m a
withOnlineBackend floatMode gen feats action = do
  st  <- liftIO $ initialOnlineBackendState gen feats
  sym <- liftIO $ B.newExprBuilder floatMode st gen
  liftIO $ extendConfig onlineBackendOptions (getConfiguration sym)
  liftIO $ writeIORef (B.sbStateManager sym) st

  action sym
    `finally`
    (liftIO $ readIORef (solverProc st) >>= \case
        SolverNotStarted {} -> return ()
        SolverStarted p auxh ->
          ((void $ shutdownSolverProcess p) `onException` (killSolver p))
            `finally`
          (maybe (return ()) hClose auxh)
    )


instance OnlineSolver scope solver => IsBoolSolver (OnlineBackend scope solver fs) where

  addDurableProofObligation sym a =
     AS.addProofObligation a =<< getAssumptionStack sym

  addAssumption sym a =
    let cond = asConstantPred (a^.labeledPred)
    in case cond of
         Just False -> abortExecBecause (AssumedFalse (a^.labeledPredMsg))
         _ -> -- Send assertion to the solver, unless it is trivial.
              -- NB, don't add the assumption to the assumption stack unless
              -- the solver assumptions succeeded
              withSolverConn sym $ \conn ->
               do case cond of
                    Just True -> return ()
                    _ -> SMT.assume conn (a^.labeledPred)

                  -- Record assumption, even if trivial.
                  -- This allows us to keep track of the full path we are on.
                  AS.assume a =<< getAssumptionStack sym

  addAssumptions sym a =
    -- NB, don't add the assumption to the assumption stack unless
    -- the solver assumptions succeeded
    withSolverConn sym $ \conn ->
      do -- Tell the solver of assertions
         mapM_ (SMT.assume conn . view labeledPred) (toList a)
         -- Add assertions to list
         stk <- getAssumptionStack sym
         appendAssumptions a stk

  getPathCondition sym =
    do stk <- getAssumptionStack sym
       ps <- AS.collectAssumptions stk
       andAllOf sym (folded.labeledPred) ps

  collectAssumptions sym =
    AS.collectAssumptions =<< getAssumptionStack sym

  pushAssumptionFrame sym =
    -- NB, don't push a frame in the assumption stack unless
    -- pushing to the solver succeeded
    withSolverProcess sym $ \proc ->
      do push proc
         pushFrame =<< getAssumptionStack sym

  popAssumptionFrame sym ident =
    -- NB, pop the frame whether or not the solver pop succeeds
    do frm <- popFrame ident =<< getAssumptionStack sym
       withSolverProcess sym pop
       return frm

  popUntilAssumptionFrame sym ident =
    -- NB, pop the frames whether or not the solver pop succeeds
    do n <- AS.popFramesUntil ident =<< getAssumptionStack sym
       withSolverProcess sym $ \proc ->
         forM_ [0..(n-1)] $ \_ -> pop proc

  popAssumptionFrameAndObligations sym ident = do
    -- NB, pop the frames whether or not the solver pop succeeds
    do frmAndGls <- popFrameAndGoals ident =<< getAssumptionStack sym
       withSolverProcess sym pop
       return frmAndGls

  getProofObligations sym =
    do stk <- getAssumptionStack sym
       AS.getProofObligations stk

  clearProofObligations sym =
    do stk <- getAssumptionStack sym
       AS.clearProofObligations stk

  saveAssumptionState sym =
    do stk <- getAssumptionStack sym
       AS.saveAssumptionStack stk

  restoreAssumptionState sym gc =
    do st <- readIORef (B.sbStateManager sym)
       mproc <- readIORef (solverProc st)
       let stk = assumptionStack st

       -- restore the previous assumption stack
       AS.restoreAssumptionStack gc stk

       case mproc of
         -- Nothing to do, state will be restored next time we start the process
         SolverNotStarted -> return ()

         SolverStarted proc auxh ->
           (do -- reset the solver state
               reset proc
               -- restore the assumption structure
               restoreAssumptionFrames proc (PG.gcFrames gc))
             `onException`
            ((killSolver proc)
               `finally`
             (maybe (return ()) hClose auxh)
               `finally`
             (writeIORef (solverProc st) SolverNotStarted))
