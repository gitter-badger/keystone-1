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
import Data.Time.Clock (getCurrentTime, UTCTime)

import Language.Haskell.TH.Syntax (nameBase)

import qualified Data.Text as T
import qualified Database.MongoDB as M
import qualified Model.Project as MP
import qualified Model.Role as MR
import qualified Model.Service as MS
import qualified Model.User as MU

collectionName :: M.Collection
collectionName = "token"

data Token = Token { _id       :: M.ObjectId
                   , issuedAt  :: UTCTime
                   , expiresAt :: UTCTime
                   , user      :: MU.User
                   , project   :: Maybe MP.Project -- currently only project scope is available
                   , roles     :: [MR.Role]
                   , services  :: [MS.Service]
                   } deriving (Show, Eq, Typeable)

$(deriveBson id ''Token)

createToken :: MonadIO m => Token -> M.Action m M.Value
createToken t =
  M.insert collectionName $ toBson t

findTokenById :: MonadIO m => ObjectId -> M.Action m (Maybe Token)
findTokenById tid = runMaybeT $ do
  mToken <- MaybeT $ M.findOne (M.select [idF =: tid] collectionName)
  fromBson mToken

validateToken :: MonadIO m => ObjectId -> M.Action m Bool
validateToken tid = do
  currentTime <- liftIO getCurrentTime
  res <- runMaybeT $ do
    token <- MaybeT $ M.findOne
                          $ (M.select [idF =: tid] collectionName)
                {M.project = [ (T.pack $ nameBase 'expiresAt) =: (M.Int32 1) ]}
    (M.UTC time) <- MaybeT $ return $ M.look
                                          (T.pack $ nameBase 'expiresAt)
                                          token
    if currentTime > time
      then return False
      else return True
  case res of
    Just v  -> return v
    Nothing -> return False
