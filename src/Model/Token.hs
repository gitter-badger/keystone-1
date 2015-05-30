{-# LANGUAGE OverloadedStrings #-}
{-# Language DeriveDataTypeable #-}
{-# Language TemplateHaskell #-}
module Model.Token
where

import Common.Database (idF)

import Control.Monad (liftM)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Maybe (MaybeT(..))

import Data.Aeson.Types (Value(..), (.=), object, ToJSON(..))
import Data.Bson ((=:), ObjectId)
import Data.Bson.Mapping (Bson(..), deriveBson)
import Data.Data (Typeable)
import Data.Maybe (fromJust)
import Data.Time.Clock (UTCTime)

import qualified Data.Text as T
import qualified Database.MongoDB as M
import qualified Model.User as MU

collectionName :: M.Collection
collectionName = "token"

data Token = Token { issuedAt  :: UTCTime
                   , expiresAt :: UTCTime
                   , user      :: M.ObjectId
                   , project   :: Maybe M.ObjectId -- currently only project scope is available
                   } deriving (Show, Read, Eq, Ord, Typeable)

$(deriveBson id ''Token)

createToken :: MonadIO m => Token -> M.Action m M.Value
createToken t =
  M.insert collectionName $ toBson t

findTokenById :: MonadIO m => ObjectId -> M.Action m (Maybe Token)
findTokenById tid = runMaybeT $ do
  mToken <- MaybeT $ M.findOne (M.select [idF =: tid] collectionName)
  fromBson mToken
