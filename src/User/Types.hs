module User.Types
where

data UserCreateRequest = UserCreateRequest
                       { defaultProjectId :: String
                       , description :: Maybe String
                       , domainId :: Maybe String
                       , email :: Maybe String
                       , enabled :: Bool
                       , name :: String
                       , password :: Maybe String
                       } deriving Show

data UserUpdateRequest = UserUpdateRequest
                       { udefaultProjectId :: Maybe String
                       , udescription :: Maybe String
                       , udomainId :: Maybe String
                       , uemail :: Maybe String
                       , uenabled :: Maybe Bool
                       , uname :: Maybe String
                       , upassword :: Maybe String
                       } deriving Show

data ChangePasswordRequest = ChangePasswordRequest
                           { poriginalPassword :: String
                           , ppassword         :: String
                           } deriving Show
