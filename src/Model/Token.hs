{-# LANGUAGE OverloadedStrings #-}
{-# Language DeriveDataTypeable #-}
{-# Language TemplateHaskell #-}
module Model.Token
where

import Control.Monad (liftM)
import Control.Monad.IO.Class (MonadIO(..))

import Data.Aeson.Types (Value, (.=), object)
import Data.Bson.Mapping (Bson(..), deriveBson)
import Data.Data (Typeable)
import Data.Maybe (fromJust)
import Data.Time.Clock (UTCTime)

import qualified Database.MongoDB as M
import qualified Model.User as MU

collectionName :: M.Collection
collectionName = "token"

data Token = Token { issuedAt  :: UTCTime
                   , expiresAt :: UTCTime
                   , user      :: String
                   } deriving (Show, Read, Eq, Ord, Typeable)

$(deriveBson ''Token)

produceTokenResponse :: MonadIO m => Token -> M.Action m Value
produceTokenResponse (Token issued expires user) = do
  u <- fromJust `liftM` MU.findUserById user
  return $ object [ "token" .= ( object [ "expires_at" .= expires
                                        , "issued_at"  .= issued
                                        , "methods"    .= [ "password" :: String ]
                                        , "extras"    .= (object [])
                                        , "user"       .= (object [ "name"   .= MU.name u
                                                                  , "id"     .= user
                                                                  , "domain" .= ( object [ "name" .= ("Default" :: String)
                                                                                         , "id"   .= ("default" :: String)])
                                                                  ] )
                                        ])
                  ]

createToken :: MonadIO m => Token -> M.Action  m M.Value
createToken t =
  M.insert collectionName $ toBson t