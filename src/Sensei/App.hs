{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Sensei.App where

import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception.Safe (catch, throwM, try)
import Control.Monad.Except
import Control.Monad.Reader (ReaderT (runReaderT))
import Data.Aeson (encode)
import Data.ByteString.Lazy (fromStrict, toStrict)
import qualified Data.ByteString.Lazy as LBS
import Data.Either (isLeft)
import Data.Maybe (fromMaybe)
import Data.Swagger (Swagger)
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Network.CORS (WithCORS (..))
import Preface.Log
import Preface.Server
import Sensei.API
import Sensei.DB
import Sensei.DB.Log ()
import Sensei.DB.SQLite
import Sensei.IO
import Sensei.Server
import Sensei.Version
import Servant
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.Posix.Daemonize

type FullAPI =
  "swagger.json" :> Get '[JSON] Swagger
    :<|> LoginAPI
    :<|> Protected
      :> ( KillServer
             :<|> SetCurrentTime
             :<|> GetCurrentTime
             :<|> (CheckVersion $(senseiVersionTH) :> SenseiAPI)
         )
    :<|> Raw

fullAPI :: Proxy FullAPI
fullAPI = Proxy

daemonizeServer :: IO ()
daemonizeServer = do
  configDir <- getConfigDirectory
  setEnv "ENVIRONMENT" "Prod"
  setEnv "SENSEI_SERVER_CONFIG_DIR" configDir
  getKeyAsString configDir >>= setEnv "SENSEI_SERVER_KEY"
  daemonize $ startServer configDir

getKeyAsString :: FilePath -> IO String
getKeyAsString configDir = do
  let keyFile = configDir </> "sensei.jwk"
  key <-
    getKey keyFile
      `catch` ( \(_ :: IOError) -> do
                  k <- makeNewKey
                  LBS.writeFile keyFile $ encode k
                  pure k
              )
  pure $ unpack . decodeUtf8 . toStrict . encode $ key

startServer :: FilePath -> IO ()
startServer configDir =
  getDataFile configDir >>= sensei

sensei :: FilePath -> IO ()
sensei output = do
  signal <- newEmptyMVar
  configDir <- fromMaybe "." <$> lookupEnv "SENSEI_SERVER_CONFIG_DIR"
  key <- readOrMakeKey =<< lookupEnv "SENSEI_SERVER_KEY"
  serverName <- pack . fromMaybe "" <$> lookupEnv "SENSEI_SERVER_NAME"
  serverPort <- readPort <$> lookupEnv "SENSEI_SERVER_PORT"
  rootUser <- fmap pack <$> lookupEnv "SENSEI_SERVER_ROOT_USER"
  env <- (>>= readEnv) <$> lookupEnv "ENVIRONMENT"
  withAppServer serverName NoCORS serverPort (senseiApp env rootUser signal key output configDir) $ \server ->
    waitServer server `race_` (takeMVar signal >> stopServer server)

senseiApp :: Maybe Env -> Maybe Text -> MVar () -> JWK -> FilePath -> FilePath -> LoggerEnv -> IO Application
senseiApp env rootUser signal publicAuthKey output configDir logger = do
  runDB output configDir logger $ do
    initLogStorage
    maybe (pure ()) ensureUserExists rootUser
  let jwtConfig = defaultJWTSettings publicAuthKey
      cookieConfig = defaultCookieSettings {cookieXsrfSetting = Nothing}
      contextConfig = jwtConfig :. cookieConfig :. EmptyContext
      contextProxy :: Proxy [JWTSettings, CookieSettings]
      contextProxy = Proxy
  pure $
    serveWithContext fullAPI contextConfig $
      hoistServerWithContext fullAPI contextProxy runApp $
        pure senseiSwagger
          :<|> loginS jwtConfig cookieConfig
          :<|> validateAuth jwtConfig
          :<|> Tagged (userInterface env)
  where
    ensureUserExists userName = do
      prof <- try @_ @SQLiteDBError $ readProfile userName
      when (isLeft prof) $ void $ insertProfile (defaultProfile {userName})

    validateAuth jwtConfig (Authenticated _) = baseServer jwtConfig signal
    validateAuth _ _ = throwAll err401 {errHeaders = [("www-authenticate", "Bearer realm=\"sensei\"")]}

    runApp :: ReaderT LoggerEnv SQLiteDB x -> Handler x
    runApp = Handler . ExceptT . try . handleDBError . runDB output configDir logger . flip runReaderT logger

    handleDBError :: IO a -> IO a
    handleDBError io =
      io `catch` \(SQLiteDBError _q txt) -> throwM $ err500 {errBody = fromStrict $ encodeUtf8 txt}

baseServer ::
  (MonadIO m, DB m) =>
  JWTSettings ->
  MVar () ->
  ServerT (KillServer :<|> SetCurrentTime :<|> GetCurrentTime :<|> SenseiAPI) m
baseServer jwtSettings signal =
  killS signal
    :<|> setCurrentTimeS
    :<|> getCurrentTimeS
    :<|> ( getFlowS
             :<|> updateFlowStartTimeS
             :<|> queryFlowPeriodSummaryS
             :<|> notesDayS
             :<|> commandsDayS
             :<|> queryFlowDayS
             :<|> queryFlowS
         )
    :<|> searchNoteS
    :<|> (postEventS :<|> getLogS)
    :<|> (getFreshTokenS jwtSettings :<|> createUserProfileS :<|> getUserProfileS :<|> putUserProfileS)
    :<|> getVersionsS
    :<|> (postGoalS :<|> getGoalsS)

-- | This orphan instance is needed because of the 'validateAuth' function above
instance MonadError ServerError SQLiteDB where
  throwError = throwM
  catchError = catch
