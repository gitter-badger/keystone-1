{-# LANGUAGE OverloadedStrings #-}
module Domain
where

import Data.Aeson (Value(..))
import Data.Aeson.Types (object, (.=))
import Data.Vector (fromList)

import qualified Model.Domain as MD

produceDomainJson :: MD.Domain -> String -> Value
produceDomainJson domain baseUrl
  = object [ "description" .= ("Fake default domain" :: String)
           , "enabled"     .= True
           , "id"          .= MD.defaultDomainId
           , "links"       .=
                ( object
                [ "self" .= (baseUrl ++ "/v3/domains/" ++ MD.defaultDomainId)
                ] )
           , "name"        .= MD.defaultDomainName
           ]

produceDomainReply :: MD.Domain -> String -> Value
produceDomainReply domain baseUrl
      = object [ "domain" .= produceDomainJson domain baseUrl ]

produceDomainsReply :: [MD.Domain] -> String -> Value
produceDomainsReply domains baseUrl
  = object [ "links" .= (object [ "next"     .= Null
                                , "previous" .= Null
                                , "self"     .= (baseUrl ++ "/v3/domains")
                                ]
                        )
           , "domains" .= (Array $ fromList [produceDomainJson MD.Domain baseUrl])
           ]
