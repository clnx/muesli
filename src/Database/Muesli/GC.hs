-----------------------------------------------------------------------------
-- |
-- Module : Database.Muesli.GC
-- Copyright : (C) 2015 Călin Ardelean,
-- License : MIT (see the file LICENSE)
--
-- Maintainer : Călin Ardelean <calinucs@gmail.com>
-- Stability : experimental
-- Portability : portable
--
-- This module provides the Garbage Collector for the database.
----------------------------------------------------------------------------

module Database.Muesli.GC
  ( gcThread
  , withGC
  , reserveIdsRec
  ) where

import           Control.Concurrent        (threadDelay)
import           Control.Monad             (forM_, unless, when)
import           Data.Function             (on)
import           Data.IntMap.Strict        ((\\))
import qualified Data.IntMap.Strict        as Map
import           Data.List                 (foldl', groupBy, sortOn)
import           Database.Muesli.Allocator
import           Database.Muesli.IdSupply
import           Database.Muesli.Indexes
import           Database.Muesli.Internal
import           Database.Muesli.Utils
import           System.Directory          (renameFile)
import qualified System.IO                 as IO

gcThread :: Handle -> IO ()
gcThread h = do
  sgn <- withGC h $ \sgn -> do
    when (sgn == PerformGC) $ do
      (mainIdxOld, logCompOld) <- withMaster h $ \m ->
        return (m { keepTrans = True }, (mainIdx m, logComp m))
      let rs  = map head . filter (not . any docDel) $ Map.elems mainIdxOld
      let (rs2, dpos) = realloc 0 rs
      let rs' = sortOn docTID $ map fst rs2
      let ts  = concatMap toTRecs $ groupBy ((==) `on` docTID) rs'
      let ids = foldl' reserveIdsRec emptyIdSupply . map fromPending $
                filter isPending ts
      let pos = sum $ tRecSize <$> ts
      let logPath = logFilePath (unHandle h)
      let logPathNew = logPath ++ ".new"
      sz <- IO.withBinaryFile logPathNew IO.ReadWriteMode $ writeTrans 0 pos ts
      let dataPath = dataFilePath (unHandle h)
      let dataPathNew = dataPath ++ ".new"
      IO.withBinaryFile dataPathNew IO.ReadWriteMode $ writeData rs2 dpos h
      let mIdx = updateMainIdx Map.empty rs'
      let uIdx = updateUnqIdx  Map.empty rs'
      let iIdx = updateIntIdx  Map.empty rs'
      let rIdx = updateRefIdx  Map.empty rs'
      when (forceEval mIdx iIdx rIdx) $ withUpdateMan h $ \kill -> do
        withMaster h $ \nm -> do
          let (ncrs', dpos') = realloc dpos . concat . Map.elems $
                               logComp nm \\ logCompOld
          let (logp', dpos'') = realloc' dpos' $ logPend nm
          let ncrs = fst <$> ncrs'
          (pos', sz') <-
            if null ncrs then return (pos, sz)
            else IO.withBinaryFile logPathNew IO.ReadWriteMode $ \hnd -> do
                   let newts = toTRecs ncrs
                   let pos' = pos + sum (tRecSize <$> newts)
                   sz' <- writeTrans sz pos' newts hnd
                   return (pos', sz')
          IO.hClose $ logHandle nm
          renameFile logPathNew logPath
          hnd <- IO.openBinaryFile logPath IO.ReadWriteMode
          IO.hSetBuffering hnd IO.NoBuffering
          IO.withBinaryFile dataPathNew IO.ReadWriteMode $ writeData ncrs' dpos'' h
          let gs = buildExtraGaps dpos'' . filter docDel $
                     ncrs ++ (map fst . concat $ Map.elems logp')
          let m = MasterState { logHandle = hnd
                              , logPos    = fromIntegral pos'
                              , logSize   = fromIntegral sz'
                              , idSupply  = ids
                              , keepTrans = False
                              , gaps      = gs
                              , logPend   = logp'
                              , logComp   = Map.empty
                              , mainIdx   = updateMainIdx mIdx ncrs
                              , unqIdx    = updateUnqIdx  uIdx ncrs
                              , intIdx    = updateIntIdx  iIdx ncrs
                              , refIdx    = updateRefIdx  rIdx ncrs
                              }
          return (m, ())
        withData h $ \(DataState hnd cache) -> do
          IO.hClose hnd
          renameFile dataPathNew dataPath
          hnd' <- IO.openBinaryFile dataPath IO.ReadWriteMode
          IO.hSetBuffering hnd' IO.NoBuffering
          return (DataState hnd' cache, ())
        return (kill, ())
    let sgn' = if sgn == PerformGC then IdleGC else sgn
    return (sgn', sgn')
  unless (sgn == KillGC) $ do
    threadDelay $ 1000 * 1000
    gcThread h
  where
    toTRecs rs = foldl' (\ts r -> Pending r : ts)
                 [Completed . docTID $ head rs] rs

    writeTrans osz pos ts hnd = do
      sz <- checkLogSize hnd osz pos
      IO.hSeek hnd IO.AbsoluteSeek $ fromIntegral dbWordSize
      forM_ ts $ writeLogTRec hnd
      writeLogPos hnd $ fromIntegral pos
      return sz

    writeData rs sz h hnd = do
      IO.hSetFileSize hnd $ fromIntegral sz
      forM_ rs $ \(r, oldr) -> do
        bs <- withDataLock h $ \(DataState hnd _) -> readDocumentFromFile hnd oldr
        writeDocument r bs hnd

    realloc st = foldl' f ([], st)
      where f (nrs, pos) r =
              if docDel r then ((r, r) : nrs, pos)
              else ((r { docAddr = pos }, r) : nrs, pos + docSize r)

    realloc' st idx = (Map.fromList l, pos)
      where (l, pos) = foldl' f ([], st) $ Map.toList idx
            f (lst, pos) (tid, rs) = ((tid, rs') : lst, pos')
              where (rss', pos') = realloc pos $ fst <$> rs
                    rs' = (fst <$> rss') `zip` (snd <$> rs)

    buildExtraGaps pos = foldl' f (emptyGaps pos)
      where f gs r = addGap (docSize r) (docAddr r) gs

    forceEval mIdx iIdx rIdx = Map.notMember (-1) mIdx &&
                               Map.size iIdx > (-1) &&
                               Map.size rIdx > (-1)

reserveIdsRec :: IdSupply -> DocRecord -> IdSupply
reserveIdsRec s r = reserveId (docTID r) $ reserveId (docID r) s
