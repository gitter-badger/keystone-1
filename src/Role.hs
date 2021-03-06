{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module Role
( module Role
, module Role.Types
) where

import Common (underscoreOptions)
import Data.Aeson (FromJSON(..), Value(..), (.:))
import Data.Aeson.TH (mkParseJSON)
import Data.Aeson.Types (typeMismatch)
import Data.Maybe (fromMaybe)
import Role.Types
import Language.Haskell.TH.Syntax (nameBase)

import qualified Database.MongoDB as M
import qualified Model.Role as MR

newRequestToRole :: RoleCreateRequest -> IO MR.Role
newRequestToRole RoleCreateRequest{..} = do
  roleId <- M.genObjectId
  return $ MR.Role roleId name description (fromMaybe True enabled)

instance FromJSON RoleCreateRequest where
  parseJSON (Object v) = do
    role <- v .: "role"
    parseRcr role
  parseJSON v = typeMismatch (nameBase ''RoleCreateRequest) v

parseRcr = $(mkParseJSON underscoreOptions ''RoleCreateRequest)

