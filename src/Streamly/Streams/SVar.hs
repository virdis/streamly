{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MagicHash                 #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE UnboxedTuples             #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

#include "inline.h"

-- |
-- Module      : Streamly.Streams.SVar
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Streamly.Streams.SVar
    (
      fromSVar
    , toSVar
    , maxThreads
    , maxBuffer
    , maxYields
    , maxRate
    )
where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Data.Int (Int64)

import Streamly.SVar
import Streamly.Streams.StreamK
import Streamly.Streams.Serial (SerialT)

-- MVar diagnostics has some overhead - around 5% on asyncly null benchmark, we
-- can keep it on in production to debug problems quickly if and when they
-- happen, but it may result in unexpected output when threads are left hanging
-- until they are GCed because the consumer went away.

-- | Pull a stream from an SVar.
{-# NOINLINE fromStreamVar #-}
fromStreamVar :: MonadAsync m => SVar Stream m a -> Stream m a
fromStreamVar sv = Stream $ \st stp sng yld -> do
    list <- readOutputQ sv
    -- Reversing the output is important to guarantee that we process the
    -- outputs in the same order as they were generated by the constituent
    -- streams.
    unStream (processEvents $ reverse list) (rstState st) stp sng yld

    where

    allDone stp = do
#ifdef DIAGNOSTICS
#ifdef DIAGNOSTICS_VERBOSE
            svInfo <- liftIO $ dumpSVar sv
            liftIO $ hPutStrLn stderr $ "fromStreamVar done\n" ++ svInfo
#endif
#endif
            stp

    {-# INLINE processEvents #-}
    processEvents [] = Stream $ \st stp sng yld -> do
        done <- postProcess sv
        if done
        then allDone stp
        else unStream (fromStreamVar sv) (rstState st) stp sng yld

    processEvents (ev : es) = Stream $ \st stp sng yld -> do
        let rest = processEvents es
        case ev of
            ChildYield a -> yld a rest
            ChildStop tid e -> do
                -- XXX do we need this here?
                case expectedYieldLatency sv of
                    Nothing -> return ()
                    Just _ -> liftIO (collectLatency sv) >> return ()
                accountThread sv tid
                case e of
                    Nothing -> unStream rest (rstState st) stp sng yld
                    Just ex -> throwM ex

{-# INLINE fromSVar #-}
fromSVar :: (MonadAsync m, IsStream t) => SVar Stream m a -> t m a
fromSVar sv = fromStream $ fromStreamVar sv

-- | Write a stream to an 'SVar' in a non-blocking manner. The stream can then
-- be read back from the SVar using 'fromSVar'.
toSVar :: (IsStream t, MonadAsync m) => SVar Stream m a -> t m a -> m ()
toSVar sv m = toStreamVar sv (toStream m)

-------------------------------------------------------------------------------
-- Concurrency control
-------------------------------------------------------------------------------
--
-- XXX need to write these in direct style otherwise they will break fusion.
--
-- | Specify the maximum number of threads that can be spawned concurrently
-- when using concurrent streams. This values denotes maximum in-flight
-- requests or tasks in progress at any given point of time. Note that this is
-- not the grand total number of threads but maximum threads at each point of
-- concurrency.
-- A value of 0 resets the thread limit to default, a negative value means
-- there is no limit. The default value is 1500.
--
-- @since 0.4.0
{-# INLINE_NORMAL maxThreads #-}
maxThreads :: IsStream t => Int -> t m a -> t m a
maxThreads n m = fromStream $ Stream $ \st stp sng yld -> do
    let n' = if n == 0 then defaultMaxThreads else n
    unStream (toStream m) (st {threadsHigh = n'}) stp sng yld

{-# RULES "maxThreadsSerial serial" maxThreads = maxThreadsSerial #-}
maxThreadsSerial :: Int -> SerialT m a -> SerialT m a
maxThreadsSerial _ = id

-- | Specify the maximum size of the buffer for storing the results from
-- concurrent computations. If the buffer becomes full we stop spawning more
-- concurrent tasks until there is space in the buffer.
-- A value of 0 resets the buffer size to default, a negative value means
-- there is no limit. The default value is 1500.
--
-- @since 0.4.0
{-# INLINE_NORMAL maxBuffer #-}
maxBuffer :: IsStream t => Int -> t m a -> t m a
maxBuffer n m = fromStream $ Stream $ \st stp sng yld -> do
    let n' = if n == 0 then defaultMaxBuffer else n
    unStream (toStream m) (st {bufferHigh = n'}) stp sng yld

{-# RULES "maxBuffer serial" maxBuffer = maxBufferSerial #-}
maxBufferSerial :: Int -> SerialT m a -> SerialT m a
maxBufferSerial _ = id

-- | Specify the maximum rate in number of yields per second at which the
-- stream can be generated. A value of 0 resets the rate to default, a negative
-- value means there is no limit. The default value is no limit.
--
-- @since 0.4.0
{-# INLINE_NORMAL maxRate #-}
maxRate :: IsStream t => Double -> t m a -> t m a
maxRate n m = fromStream $ Stream $ \st stp sng yld -> do
    let n' = if n == 0 then defaultMaxRate else n
    unStream (toStream m) (st {maxStreamRate = n'}) stp sng yld

{-# RULES "maxRate serial" maxRate = maxRateSerial #-}
maxRateSerial :: Double -> SerialT m a -> SerialT m a
maxRateSerial _ = id

-- | Specify the average latency, in nanoseconds, of a single threaded action
-- in a concurrent composition. Streamly can measure the latencies, but that is
-- possible only after at least one task has completed. This combinator can be
-- used to provide a latency hint so that rate control using 'maxRate' can take
-- that into account right from the beginning. When not specified then a
-- default behavior is chosen which could be too slow or too fast, and would be
-- restricted by any other control parameters configured.
-- A value of 0 indicates default behavior, a negative value means there is no
-- limit i.e. zero latency.
-- This would normally be useful only in high latency and high throughput
-- cases.
--
{-# INLINE_NORMAL serialLatency #-}
serialLatency :: IsStream t => Int64 -> t m a -> t m a
serialLatency n m = fromStream $ Stream $ \st stp sng yld -> do
    let n' = if n == 0 then defaultWorkerLatency else n
    unStream (toStream m) (st {workerLatency = n'}) stp sng yld

{-# RULES "serialLatency serial" serialLatency = serialLatencySerial #-}
serialLatencySerial :: Int64 -> SerialT m a -> SerialT m a
serialLatencySerial _ = id

-- Stop concurrent dispatches after this limit. This is useful in API's like
-- "take" where we want to dispatch only upto the number of elements "take"
-- needs.  This value applies only to the immediate next level and is not
-- inherited by everything in enclosed scope.
{-# INLINE_NORMAL maxYields #-}
maxYields :: IsStream t => Maybe Int64 -> t m a -> t m a
maxYields n m = fromStream $ Stream $ \st stp sng yld -> do
    unStream (toStream m) (st {yieldLimit = n}) stp sng yld

{-# RULES "maxYields serial" maxYields = maxYieldsSerial #-}
maxYieldsSerial :: Maybe Int64 -> SerialT m a -> SerialT m a
maxYieldsSerial _ = id
