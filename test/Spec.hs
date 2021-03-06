{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE LambdaCase #-}

import           Control.Concurrent.STM (atomically)
import           Control.Concurrent.STM.TVar (swapTVar, readTVar)
import           Data.Conduit
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Combinators as CC
import qualified Data.Conduit.Network.UDP as UDP
import           Data.Monoid ((<>))
import           Control.Monad.Identity
import           Control.Monad.IO.Class (MonadIO (liftIO))
import qualified Data.Map.Strict as Map
import           Data.Time.Calendar ( Day(ModifiedJulianDay) )
import           Data.Time.Clock ( UTCTime(..) )
import           Data.Word ( Word16 )
import           Network.Socket.Internal ( SockAddr(SockAddrInet), PortNumber )
import           Network.Socket ( HostAddress, inet_addr )
import           Data.Serialize (decode, encode)
import qualified Data.List.NonEmpty as NEL
import           Test.Hspec

import           Data.MessagePack.Aeson (packAeson, unpackAeson)
import qualified Data.Aeson as A

import qualified Core
import           Types
import           Util

withStore :: (Store -> IO ()) -> IO ()
withStore f = configure >>= \ case
  Left e -> liftIO $ fail $ "configure failed" <> show e
  Right store -> f store

zeroTime :: UTCTime
zeroTime = UTCTime (ModifiedJulianDay 0) 0

localhost :: IO HostAddress
localhost = inet_addr "127.0.0.1"

sockAddr :: HostAddress -> PortNumber -> SockAddr
sockAddr = flip SockAddrInet

makeMembers :: HostAddress -> [Member]
makeMembers host =
  let seeds = [  ("alive", IsAliveC, zeroTime, sockAddr host 4001)
               , ("suspect", IsSuspectC, zeroTime, sockAddr host 4002)
               , ("dead", IsDeadC, zeroTime, sockAddr host 4003)]
  in map (\(name, status, timeChanged, addr) ->
             Member { memberName = name
                    , memberHost = "127.0.0.1"
                    , memberAlive = status
                    , memberIncarnation = 0
                    , memberLastChange = timeChanged
                    , memberHostNew = addr }) seeds

membersMap :: [Member] -> Map.Map String Member
membersMap ms =
  Map.fromList $ map (\m -> (memberName m, m)) ms

currentIncarnation :: Store -> IO Int
currentIncarnation Store{..} = atomically $ readTVar storeIncarnation

envelope :: [Message] -> Envelope
envelope msgs = Envelope $ NEL.fromList msgs

backAndForthForeverAndEver :: [Message] -> Either String Envelope
backAndForthForeverAndEver msgs = decode (encode $ envelope msgs)

main :: IO ()
main = localhost >>= \hostAddr ->
  hspec $ do
    let addr = sockAddr hostAddr 4000
        defaultMembers = makeMembers hostAddr

    describe "wire protocol" $
      it "encodes & decodes" $ do
        let msgPack = unpackAeson . packAeson
            json = A.decode . A.encode
            ping = Ping { seqNo = 1, node = "a" }
            indirectPing = IndirectPing { seqNo = 2, target = 1, port = 4000 :: Word16, node = "b" }
            ack = Ack { seqNo = 2, payload = [] }
            ping2 = Ping { seqNo = 3, node = "b" }
            ack2 = Ack { seqNo = 4, payload = [] }
            msgs = [ping, ack, ping2, ack2]

        json ping `shouldBe` Just ping
        json indirectPing `shouldBe` Just indirectPing

        msgPack ping `shouldBe` Just ping
        msgPack indirectPing `shouldBe` Just indirectPing

        backAndForthForeverAndEver [ping] `shouldBe` Right (envelope [ping])
        backAndForthForeverAndEver [indirectPing] `shouldBe` Right (envelope [indirectPing])
        backAndForthForeverAndEver msgs `shouldBe` Right (envelope msgs)

    describe "Core.removeDeadNodes" $
      it "removes dead members" $ withStore $ \s@Store{..} -> do
        _ <- atomically $ do
          void $ swapTVar storeMembers $ membersMap defaultMembers
          void $ Core.removeDeadNodes s
        mems' <- atomically $ readTVar storeMembers

        Map.notMember "dead" mems' `shouldBe` True
        Map.size mems' `shouldBe` 2

    describe "Core.kRandomMembers" $ do
      let ms = defaultMembers

      it "takes no nodes if n is 0" $ withStore $ \s@Store{..} -> do
        void $ atomically $ swapTVar storeMembers $ membersMap ms

        rand <- Core.kRandomMembers s 0 ms
        length rand `shouldBe` 0

      it "filters non-alive nodes" $ withStore $ \s@Store{..} -> do
        void $ atomically $ swapTVar storeMembers $ membersMap ms

        rand <- Core.kRandomMembers s 3 []
        length rand `shouldBe` 1
        head rand `shouldBe` head ms

      it "filters exclusion nodes" $ withStore $ \s@Store{..} -> do
        void $ atomically $ swapTVar storeMembers $ membersMap ms

        rand <- Core.kRandomMembers s 3 [head ms]
        length rand `shouldBe` 0

      it "shuffles" $ withStore $ \s@Store{..} -> do
        let alives = zipWith (\m i -> m { memberName = "alive-" <> show i }) (replicate total $ head defaultMembers) ([0..] :: [Integer])
            total = 200
            n = 50
        void $ atomically $ swapTVar storeMembers $ membersMap alives

        rand <- Core.kRandomMembers s n []
        length rand `shouldBe` n
        total `shouldNotBe` n
        rand `shouldNotBe` alives

    describe "Core.handleUDPMessage" $ do
      let ping = Ping 1 "myself"
          ack = Ack 1 []
          indirectPing (SockAddrInet port target) = IndirectPing 1 (fromIntegral target) (fromIntegral port) "other"
          send s msg = do
            let udpMsg = UDP.Message (encode $ envelope [msg]) addr
            CL.sourceList [udpMsg] $$ Core.handleUDPMessage s =$= CC.sinkList
          invokesAckHandler = undefined

      it "gets Ping for us, responds with Ack" $ withStore $ \s@Store{..} -> do
        gossip <- send s ping

        gossip `shouldBe` [Direct (Ack 1 []) addr]

      it "gets Ping for someone else, ignores msg" $ withStore $ \s@Store{..} -> do
        gossip <- send s $ Ping 1 "unknown-node"

        gossip `shouldBe` []

      it "gets Ack, invokes ackHandler" $ withStore $ \s@Store{..} -> do
        pending
        gossip <- send s ack

        gossip `shouldBe` []

      it "gets IndirectPing, sends Ping" $ withStore $ \s@Store{..} -> do
        let indirectPing' = indirectPing addr
            udpMsg = UDP.Message (encode $ envelope [indirectPing']) addr
        beforeInc <- currentIncarnation s
        gossip <- send s indirectPing'
        afterInc <- currentIncarnation s

        beforeInc + 1 `shouldBe` afterInc
        gossip `shouldBe` [Direct (Ping 1 (node indirectPing')) addr]

      it "gets Suspect" $ withStore $ \s@Store{..} -> do
        pending

      it "gets Dead" $ withStore $ \s@Store{..} -> do
        pending

      it "gets Alive" $ withStore $ \s@Store{..} -> do
        pending
