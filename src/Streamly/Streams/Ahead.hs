{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving#-}
{-# LANGUAGE InstanceSigs              #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

-- |
-- Module      : Streamly.Streams.Ahead
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Streamly.Streams.Ahead
    (
      AheadT
    , Ahead
    , aheadly
    , ahead
    )
where

import Control.Monad (ap)
import Control.Monad.Base (MonadBase(..), liftBaseDefault)
import Control.Monad.Catch (MonadThrow, throwM)
-- import Control.Monad.Error.Class   (MonadError(..))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Data.Atomics (atomicModifyIORefCAS_)
import Data.Heap (Heap, Entry(..))
import Data.IORef (IORef, readIORef)
import Data.Maybe (fromJust)
import Data.Semigroup (Semigroup(..))

import qualified Data.Heap as H

import Streamly.Streams.SVar (fromSVar)
import Streamly.Streams.Serial (map)
import Streamly.SVar
import Streamly.Streams.StreamK (IsStream(..), Stream(..))
import qualified Streamly.Streams.StreamK as K

#ifdef DIAGNOSTICS
import Control.Monad (when)
import Data.IORef (writeIORef)
#endif
import Prelude hiding (map)

#include "Instances.hs"

-------------------------------------------------------------------------------
-- Ahead
-------------------------------------------------------------------------------

-- Lookahead streams can execute multiple tasks concurrently, ahead of time,
-- but always serve them in the same order as they appear in the stream. To
-- implement lookahead streams efficiently we assign a sequence number to each
-- task when the task is picked up for execution. When the task finishes, the
-- output is tagged with the same sequence number and we rearrange the outputs
-- in sequence based on that number.
--
-- To explain the mechanism imagine that the current task at the head of the
-- stream has a "token" to yield to the outputQueue. The ownership of the token
-- is determined by the current sequence number is maintained in outputHeap.
-- Sequence number is assigned when a task is queued. When a thread dequeues a
-- task it picks up the sequence number as well and when the output is ready it
-- uses the sequence number to queue the output to the outputQueue.
--
-- The thread with current sequence number sends the output directly to the
-- outputQueue. Other threads push the output to the outputHeap. When the task
-- being queued on the heap is a stream of many elements we evaluate only the
-- first element and keep the rest of the unevaluated computation in the heap.
-- When such a task gets the "token" for outputQueue it evaluates and directly
-- yields all the elements to the outputQueue without checking for the
-- "token".
--
-- Note that no two outputs in the heap can have the same sequence numbers and
-- therefore we do not need a stable heap. We have also separated the buffer
-- for the current task (outputQueue) and the pending tasks (outputHeap) so
-- that the pending tasks cannot interfere with the current task. Note that for
-- a single task just the outputQueue is enough and for the case of many
-- threads just a heap is good enough. However we balance between these two
-- cases, so that both are efficient.
--
-- For bigger streams it may make sense to have separate buffers for each
-- stream. However, for singleton streams this may become inefficient. However,
-- if we do not have separate buffers, then the streams that come later in
-- sequence may hog the buffer, hindering the streams that are ahead. For this
-- reason we have a single element buffer limitation for the streams being
-- executed in advance.
--
-- This scheme works pretty efficiently with less than 40% extra overhead
-- compared to the Async streams where we do not have any kind of sequencing of
-- the outputs. It is especially devised so that we are most efficient when we
-- have short tasks and need just a single thread. Also when a thread yields
-- many items it can hold lockfree access to the outputQueue and do it
-- efficiently.
--
-- XXX Maybe we can start the ahead threads at a lower cpu and IO priority so
-- that they do not hog the resources and hinder the progress of the threads in
-- front of them.

-- Left associated ahead expressions are expensive. We start a new SVar for
-- each left associative expression. The queue is used only for right
-- associated expression, we queue the right expression and execute the left.
-- Thererefore the queue never has more than on item in it.

workLoopAhead :: MonadIO m
    => State Stream m a
    -> IORef ([Stream m a], Int)
    -> IORef (Heap (Entry Int (AheadHeapEntry Stream m a)) , Int)
    -> m ()
workLoopAhead st q heap = runHeap

    where

    sv = fromJust $ streamVar st
    maxBuf = bufferHigh st
    toHeap seqNo ent = do
        hp <- liftIO $ atomicModifyIORefCAS heap $ \(h, snum) ->
            ((H.insert (Entry seqNo ent) h, snum), h)
        (_, len) <- liftIO $ readIORef (outputQueue sv)
        let maxHeap = maxBuf - len
        limit <- case maxYieldLimit sv of
            Nothing -> return maxHeap
            Just ref -> do
                r <- liftIO $ readIORef ref
                return $ if r >= 0 then r else maxHeap
        if H.size hp <= limit
        then runHeap
        else liftIO $ sendStop sv

    singleToHeap seqNo a = toHeap seqNo (AheadEntryPure a)
    yieldToHeap seqNo a r = toHeap seqNo (AheadEntryStream (a `K.cons` r))

    singleOutput seqNo a = do
        continue <- liftIO $ sendYield maxBuf sv (ChildYield a)
        if continue
        then runQueueToken seqNo
        else liftIO $ do
            atomicModifyIORefCAS_ heap $ \(h, _) -> (h, seqNo + 1)
            sendStop sv

    yieldOutput seqNo a r = do
        continue <- liftIO $ sendYield maxBuf sv (ChildYield a)
        if continue
        then unStream r st (runQueueToken seqNo)
                           (singleOutput seqNo)
                           (yieldOutput seqNo)
        else liftIO $ do
            atomicModifyIORefCAS_ heap $ \(h, _) ->
                (H.insert (Entry seqNo (AheadEntryStream r)) h, seqNo)
            sendStop sv

    {-# INLINE runQueueToken #-}
    runQueueToken prevSeqNo = do
        work <- dequeueAhead q
        case work of
            Nothing -> do
                liftIO $ atomicModifyIORefCAS_ heap $ \(h, _) ->
                    (h, prevSeqNo + 1)
                runHeap
            Just (m, seqNo) -> do
                if seqNo == prevSeqNo + 1
                then
                    unStream m st (runQueueToken seqNo)
                                  (singleOutput seqNo)
                                  (yieldOutput seqNo)
                else do
                    liftIO $ atomicModifyIORefCAS_ heap $ \(h, _) ->
                        (h, prevSeqNo + 1)
                    unStream m st runHeap
                                  (singleToHeap seqNo)
                                  (yieldToHeap seqNo)
    runQueueNoToken = do
        work <- dequeueAhead q
        case work of
            Nothing -> runHeap
            Just (m, seqNo) -> do
                if seqNo == 0
                then
                    unStream m st (runQueueToken seqNo)
                                  (singleOutput seqNo)
                                  (yieldOutput seqNo)
                else
                    unStream m st runHeap
                                  (singleToHeap seqNo)
                                  (yieldToHeap seqNo)

    {-# NOINLINE runHeap #-}
    runHeap = do
#ifdef DIAGNOSTICS
        liftIO $ do
            maxHp <- readIORef (maxHeapSize sv)
            (hp, _) <- readIORef heap
            when (H.size hp > maxHp) $ writeIORef (maxHeapSize sv) (H.size hp)
#endif
        ent <- liftIO $ dequeueFromHeap heap
        case ent of
            Nothing -> do
                done <- queueEmptyAhead q
                if done
                then liftIO $ sendStop sv
                else runQueueNoToken
            Just (Entry seqNo hent) -> do
                case hent of
                    AheadEntryPure a -> singleOutput seqNo a
                    AheadEntryStream r ->
                        unStream r st (runQueueToken seqNo)
                                      (singleOutput seqNo)
                                      (yieldOutput seqNo)

-------------------------------------------------------------------------------
-- WAhead
-------------------------------------------------------------------------------

-- XXX To be implemented. Use a linked queue like WAsync and put back the
-- remaining computation at the back of the queue instead of the heap, and
-- increment the sequence number.

-- The only difference between forkSVarAsync and this is that we run the left
-- computation without a shared SVar.
forkSVarAhead :: MonadAsync m => Stream m a -> Stream m a -> Stream m a
forkSVarAhead m1 m2 = Stream $ \st stp sng yld -> do
        sv <- newAheadVar st (concurrently m1 m2) workLoopAhead
        unStream (fromSVar sv) (rstState st) stp sng yld
    where
    concurrently ma mb = Stream $ \st stp sng yld -> do
        liftIO $ enqueue (fromJust $ streamVar st) mb
        unStream ma (rstState st) stp sng yld

{-# INLINE aheadS #-}
aheadS :: MonadAsync m => Stream m a -> Stream m a -> Stream m a
aheadS m1 m2 = Stream $ \st stp sng yld -> do
    case streamVar st of
        Just sv | svarStyle sv == AheadVar -> do
            liftIO $ enqueue sv m2
            -- Always run the left side on a new SVar to avoid complexity in
            -- sequencing results. This means the left side cannot further
            -- split into more ahead computations on the same SVar.
            unStream m1 (rstState st) stp sng yld
        _ -> unStream (forkSVarAhead m1 m2) st stp sng yld

-- | XXX we can implement it more efficienty by directly implementing instead
-- of combining streams using ahead.
{-# INLINE consMAhead #-}
consMAhead :: MonadAsync m => m a -> Stream m a -> Stream m a
consMAhead m r = K.yieldM m `aheadS` r

------------------------------------------------------------------------------
-- AheadT
------------------------------------------------------------------------------

-- | Deep ahead composition or ahead composition with depth first traversal.
-- The semigroup composition of 'AheadT' appends streams in a depth first
-- manner just like 'SerialT' except that it can produce elements concurrently
-- ahead of time. It is like 'AsyncT' except that 'AsyncT' produces the output
-- as it arrives whereas 'AheadT' orders the output in the traversal order.
--
-- @
-- main = ('toList' . 'aheadly' $ (fromFoldable [1,2]) \<> (fromFoldable [3,4])) >>= print
-- @
-- @
-- [1,2,3,4]
-- @
--
-- Any exceptions generated by a constituent stream are propagated to the
-- output stream.
--
-- Similarly, the monad instance of 'AheadT' may run each iteration
-- concurrently ahead of time but presents the results in the same order as
-- 'SerialT'.
--
-- @
-- import "Streamly"
-- import qualified "Streamly.Prelude" as S
-- import Control.Concurrent
--
-- main = 'runStream' . 'aheadly' $ do
--     n <- return 3 \<\> return 2 \<\> return 1
--     S.once $ do
--          threadDelay (n * 1000000)
--          myThreadId >>= \\tid -> putStrLn (show tid ++ ": Delay " ++ show n)
-- @
-- @
-- ThreadId 40: Delay 1
-- ThreadId 39: Delay 2
-- ThreadId 38: Delay 3
-- @
--
-- All iterations may run in the same thread if they do not block.
--
-- Note that ahead composition with depth first traversal can be used to
-- combine infinite number of streams as it explores only a bounded number of
-- streams at a time.
--
-- @since 0.3.0
newtype AheadT m a = AheadT {getAheadT :: Stream m a}
    deriving (MonadTrans)

-- | A serial IO stream of elements of type @a@ with concurrent lookahead.  See
-- 'AheadT' documentation for more details.
--
-- @since 0.3.0
type Ahead a = AheadT IO a

-- | Fix the type of a polymorphic stream as 'AheadT'.
--
-- @since 0.3.0
aheadly :: IsStream t => AheadT m a -> t m a
aheadly = K.adapt

instance IsStream AheadT where
    toStream = getAheadT
    fromStream = AheadT

    {-# INLINE consM #-}
    {-# SPECIALIZE consM :: IO a -> AheadT IO a -> AheadT IO a #-}
    consM m r = fromStream $ consMAhead m (toStream r)

    {-# INLINE (|:) #-}
    {-# SPECIALIZE (|:) :: IO a -> AheadT IO a -> AheadT IO a #-}
    (|:) = consM

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | Polymorphic version of the 'Semigroup' operation '<>' of 'AheadT'.
-- Merges two streams sequentially but with concurrent lookahead.
--
-- @since 0.3.0
{-# INLINE ahead #-}
ahead :: (IsStream t, MonadAsync m) => t m a -> t m a -> t m a
ahead m1 m2 = fromStream $ aheadS (toStream m1) (toStream m2)

instance MonadAsync m => Semigroup (AheadT m a) where
    (<>) = ahead

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------

instance MonadAsync m => Monoid (AheadT m a) where
    mempty = K.nil
    mappend = (<>)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

{-# INLINE aheadbind #-}
aheadbind
    :: MonadAsync m
    => Stream m a
    -> (a -> Stream m b)
    -> Stream m b
aheadbind m f = go m
    where
        go (Stream g) =
            Stream $ \st stp sng yld ->
            let run x = unStream x st stp sng yld
                single a   = run $ f a
                yieldk a r = run $ f a `aheadS` go r
            in g (rstState st) stp single yieldk

instance MonadAsync m => Monad (AheadT m) where
    return = pure
    (AheadT m) >>= f = AheadT $ aheadbind m (getAheadT . f)

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

MONAD_APPLICATIVE_INSTANCE(AheadT,MONADPARALLEL)
MONAD_COMMON_INSTANCES(AheadT, MONADPARALLEL)
