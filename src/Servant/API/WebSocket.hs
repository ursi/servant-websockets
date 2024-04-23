{-# LANGUAGE AllowAmbiguousTypes      #-}
{-# LANGUAGE CPP                      #-}
{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications         #-}
{-# LANGUAGE TypeFamilies             #-}

module Servant.API.WebSocket where

import           Control.Monad                       (void, (>=>))
import qualified Control.Monad.Catch                 as Catch
import           Control.Monad.IO.Class              (liftIO)
import           Control.Monad.Trans.Resource        (runResourceT)
import           Data.Aeson                          (FromJSON, ToJSON)
import qualified Data.Aeson                          as Aeson
import           Data.Kind                           (Constraint, Type)
import           Data.Proxy                          (Proxy (..))
import           Data.String                         (IsString (..))
import           Data.Typeable                       (Typeable)
import           GHC.TypeLits                        (Symbol, symbolVal)
import           Network.Wai.Handler.WebSockets      (websocketsOr)
import           Network.WebSockets                  (AcceptRequest (acceptHeaders), Connection, ConnectionException,
                                                      PendingConnection, RequestHead (requestHeaders), WebSocketsData,
                                                      acceptRequest, acceptRequestWith, defaultAcceptRequest,
                                                      defaultConnectionOptions, pendingRequest, receiveData,
                                                      sendBinaryDatas, sendTextDatas)
import qualified Network.WebSockets                  as Ws
import           Servant.Server                      (HasServer (..), ServerError (..), ServerT, runHandler)
import           Servant.Server.Internal.Delayed     (runDelayed)
import           Servant.Server.Internal.Router      (leafRouter)
import           Servant.Server.Internal.RouteResult (RouteResult (..))

-- | Endpoint for defining a route to provide a web socket. The
-- handler function gets an already negotiated websocket 'Connection'
-- to send and receive data.
--
-- Example:
--
-- > type WebSocketApi = "stream" :> WebSocket
-- >
-- > server :: Server WebSocketApi
-- > server = streamData
-- >  where
-- >   streamData :: MonadIO m => Connection -> m ()
-- >   streamData c = do
-- >     liftIO $ forkPingThread c 10
-- >     liftIO . forM_ [1..] $ \i -> do
-- >        sendTextData c (pack $ show (i :: Int)) >> threadDelay 1000000
data WebSocket

instance HasServer WebSocket ctx where

  type ServerT WebSocket m = Connection -> m ()

#if MIN_VERSION_servant_server(0,12,0)
  hoistServerWithContext _ _ nat svr = nat . svr
#endif

  route Proxy _ app = leafRouter $ \env request respond -> runResourceT $
    runDelayed app env request >>= liftIO . go request respond
   where
    go request respond (Route app') =
      websocketsOr defaultConnectionOptions (runApp app') (backupApp respond) request (respond . Route)
    go _ respond (Fail e) = respond $ Fail e
    go _ respond (FailFatal e) = respond $ FailFatal e

    runApp a = acceptRequest >=> \c -> void (runHandler $ a c)

    backupApp respond _ _ = respond $ Fail ServerError { errHTTPCode = 426
                                                       , errReasonPhrase = "Upgrade Required"
                                                       , errBody = mempty
                                                       , errHeaders = mempty
                                                       }


-- | Endpoint for defining a route to provide a web socket. The
-- handler function gets a 'PendingConnection'. It can either
-- 'rejectRequest' or 'acceptRequest'. This function is provided
-- for greater flexibility to reject connections.
--
-- Example:
--
-- > type WebSocketApi = "stream" :> WebSocketPending
-- >
-- > server :: Server WebSocketApi
-- > server = streamData
-- >  where
-- >   streamData :: MonadIO m => PendingConnection -> m ()
-- >   streamData pc = do
-- >      c <- acceptRequest pc
-- >      liftIO $ forkPingThread c 10
-- >      liftIO . forM_ [1..] $ \i ->
-- >        sendTextData c (pack $ show (i :: Int)) >> threadDelay 1000000
data WebSocketPending

instance HasServer WebSocketPending ctx where

  type ServerT WebSocketPending m = PendingConnection -> m ()

#if MIN_VERSION_servant_server(0,12,0)
  hoistServerWithContext _ _ nat svr = nat . svr
#endif

  route Proxy _ app = leafRouter $ \env request respond -> runResourceT $
    runDelayed app env request >>= liftIO . go request respond
   where
    go request respond (Route app') =
      websocketsOr defaultConnectionOptions (runApp app') (backupApp respond) request (respond . Route)
    go _ respond (Fail e) = respond $ Fail e
    go _ respond (FailFatal e) = respond $ FailFatal e

    runApp a c = void (runHandler $ a c)

    backupApp respond _ _ = respond $ Fail ServerError { errHTTPCode = 426
                                                       , errReasonPhrase = "Upgrade Required"
                                                       , errBody = mempty
                                                       , errHeaders = mempty
                                                       }
type SecWebSocketProtocol :: Symbol
type SecWebSocketProtocol = "Sec-WebSocket-Protocol"

secWebSocketProtocol :: IsString s => s
secWebSocketProtocol = fromString $ symbolVal (Proxy @SecWebSocketProtocol)

acceptance :: PendingConnection -> IO Connection
acceptance pending =
  let echoSec = case filter (\(hn, _) -> hn == secWebSocketProtocol)
        . requestHeaders $ pendingRequest pending of
        (_,yup):_ -> (:) (secWebSocketProtocol, yup)
        []        -> id
  in acceptRequestWith pending defaultAcceptRequest { acceptHeaders = echoSec $ acceptHeaders defaultAcceptRequest }

data Handler i = Handler
  { recieve :: i -> IO ()
  , handle  :: ConnectionException -> IO ()
  }

data MsgType = Text | Binary
  deriving (Typeable)

type TypedWebSocket :: MsgType -> Type -> Type -> Type
data TypedWebSocket mt i o

type SendData :: MsgType -> Type -> Constraint
class SendData mt a where
  sendData :: Connection -> [a] -> IO ()

instance WebSocketsData a => SendData 'Text a where
  sendData = sendTextDatas

instance WebSocketsData a => SendData 'Binary a where
  sendData = sendBinaryDatas

instance (WebSocketsData i, SendData mt o) => HasServer (TypedWebSocket mt i o) ctx where

  type ServerT (TypedWebSocket mt i o) m = ([o] -> IO ()) -> IO (Handler i)

#if MIN_VERSION_servant_server(0,12,0)
  hoistServerWithContext _ _ _ svr = svr
#endif

  route Proxy _ app = leafRouter $ \env request respond -> runResourceT $
    runDelayed app env request >>= liftIO . go request respond
   where
    go request respond (Route app') =
      websocketsOr defaultConnectionOptions (runApp app') (backupApp respond) request (respond . Route)
    go _ respond (Fail e) = respond $ Fail e
    go _ respond (FailFatal e) = respond $ FailFatal e

    runApp a = acceptance >=> \c -> do
      handler <- a $ sendData @mt c
      Catch.handle (handle handler)
        (let f = (receiveData c >>= recieve handler) *> f
         in f)

    backupApp respond _ _ = respond $ Fail ServerError { errHTTPCode = 426
                                                       , errReasonPhrase = "Upgrade Required"
                                                       , errBody = mempty
                                                       , errHeaders = mempty
                                                       }

newtype Aeson a = Aeson a
instance (ToJSON a, FromJSON a) => WebSocketsData (Aeson a) where
  fromDataMessage = \case
    Ws.Text bs _ -> either error Aeson $ Aeson.eitherDecode bs
    Ws.Binary _ -> error "A binary message was recieved where text was expected"
  fromLazyByteString = either error Aeson . Aeson.eitherDecode
  toLazyByteString (Aeson a) = Aeson.encode a
