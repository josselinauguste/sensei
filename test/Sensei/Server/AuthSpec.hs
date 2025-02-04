{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Sensei.Server.AuthSpec where

import Control.Exception (ErrorCall)
import Control.Monad.Trans (liftIO)
import Data.Aeson (decode, eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as LBS
import Data.Char (ord)
import Data.Functor (void)
import Data.Proxy (Proxy (..))
import Sensei.API (UserProfile (..), defaultProfile)
import Sensei.Server
  ( Credentials (..),
    Error,
    JWK,
    SerializedToken (..),
    SignedJWT,
    createKeys,
    createToken,
    decodeCompact,
    getKey,
    getPublicKey,
    setPassword,
  )
import Sensei.TestHelper
  ( MatchHeader (..),
    app,
    bodySatisfies,
    clearCookies,
    defaultHeaders,
    getJSON,
    jsonBodyEquals,
    matchBody,
    matchHeaders,
    postJSON,
    postJSON_,
    putJSON_,
    request,
    shouldNotThrow,
    shouldRespondWith,
    withApp,
    withTempDir,
  )
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "Authentication Operations" $ do
  it "can create pair of keys in given directory" $ do
    withTempDir $ \dir -> do
      createKeys dir

      jwk <- LBS.readFile (dir </> "sensei.jwk")

      (decode jwk :: Maybe JWK) `shouldNotBe` Nothing
      getKey (dir </> "sensei.jwk") `shouldNotThrow` (Proxy :: Proxy ErrorCall)

  it "can retrieve public key from private key in given directory" $ do
    withTempDir $ \dir -> do
      createKeys dir

      void $ getPublicKey dir

  it "can create token given keys exist in given directory" $ do
    withTempDir $ \dir -> do
      createKeys dir

      SerializedToken bsToken <- createToken dir

      take 2 (B64.decode <$> BS.split (fromIntegral $ ord '.') bsToken)
        `shouldBe` [Right "{\"alg\":\"PS512\"}", Right "{\"dat\":{\"auOrgID\":1,\"auID\":1}}"]

  it "can update profile with hashed password given cleartext password" $ do
    let profile = defaultProfile

    newProfile <- setPassword profile "password"

    userPassword newProfile `shouldNotBe` userPassword profile

  withApp app $
    describe "Authentication API" $ do
      it "POST /login returns 200 with user profile given user authenticates with valid password" $ do
        profile <- liftIO $ setPassword defaultProfile "password"

        putJSON_ "/api/users/arnaud" profile

        let credentials = Credentials (userName profile) "password"
        postJSON "/login" credentials `shouldRespondWith` 200 {matchHeaders = [has2Cookies], matchBody = jsonBodyEquals profile}

      it "GET /api/users/<user>/token returns fresh token given user is authenticated" $ do
        getJSON "/api/users/arnaud/token" `shouldRespondWith` 200 {matchBody = bodySatisfies isSerializedToken}

      it "POST /login returns 401 given user authenticates with invalid password" $ do
        profile <- liftIO $ setPassword defaultProfile "password"

        putJSON_ "/api/users/arnaud" profile

        let credentials = Credentials (userName profile) "wrong password"
        postJSON "/login" credentials `shouldRespondWith` 401

      it "POST /api/flows/<user> returns 200 given user authenticates with JWT contained in cookie" $ do
        profile <- liftIO $ setPassword defaultProfile "password"
        putJSON_ "/api/users/arnaud" profile
        let credentials = Credentials (userName profile) "password"
        postJSON_ "/login" credentials

        let headers = filter ((/= "Authorization") . fst) defaultHeaders

        request "GET" "/api/flows/arnaud" headers mempty `shouldRespondWith` 200

      it "POST /api/<XXX> returns 401 given user agent fails to provide Authorization header or JWT-Cookie" $ do
        profile <- liftIO $ setPassword defaultProfile "password"
        putJSON_ "/api/users/arnaud" profile
        let credentials = Credentials (userName profile) "password"
        postJSON_ "/login" credentials

        let headers = filter ((/= "Authorization") . fst) defaultHeaders
        clearCookies

        request "GET" "/api/flows/arnaud" headers mempty `shouldRespondWith` 401

has2Cookies :: MatchHeader
has2Cookies = MatchHeader $ \hdrs _ ->
  if length (filter ((== "Set-Cookie") . fst) hdrs) == 2
    then Nothing
    else Just $ "Expected 2 Set-Cookie headers, got: " <> show hdrs

isSerializedToken :: BS.ByteString -> Bool
isSerializedToken bytes =
  case eitherDecode (LBS.fromStrict bytes) of
    Right st -> either (const False) (const True) $ decodeCompact @SignedJWT @Error (LBS.fromStrict $ unToken st)
    Left _ -> False
