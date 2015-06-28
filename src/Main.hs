{-# Language BangPatterns #-}
{-# Language DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# Language TemplateHaskell #-}
module Main
where

import Common (loggerName, ScottyM, ActionM)
import Config (readConfig, KeystoneConfig(..), Database(..), ServerType(..))
import Control.Applicative ((<*>), (<$>))
import Control.Exception (bracket)
import Control.Exception.Base (throwIO)
import Control.Monad (when, MonadPlus(mzero))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Catch (MonadThrow(throwM), MonadCatch(catch), Exception, SomeException)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Except (ExceptT(..), runExceptT, MonadError(throwError))
import Control.Monad.Reader (ReaderT(..), runReaderT)
import Control.Monad.State (StateT(..), runStateT)
import Control.Monad.Trans.Resource (ResourceT, runResourceT, allocate, release)
import Data.Aeson.Types (Value, FromJSON(..))
import Data.Data (Typeable)
import Data.Bson ((=:))
import Data.ByteString.Char8 (pack, unpack)
import Data.List (lookup, or)
import Data.Maybe (isNothing, maybe, fromJust)
import Data.Time.Clock (getCurrentTime)
import Model.Common (OpStatus(..))
import Network.HTTP.Types (methodGet, methodPost)
import Network.HTTP.Types.Header (HeaderName)
import Network.HTTP.Types.Method (StdMethod(GET, HEAD))
import Network.HTTP.Types.Status ( status200, status201, status204, status401
                                 , status404, status409, status500, statusCode)
import Network.Wai ( Middleware, requestHeaders, responseLBS, rawQueryString
                   , rawPathInfo, requestMethod
                   )
import Network.Wai.Handler.Warp (defaultSettings, setPort, runSettings)
import Network.Wai.Handler.WarpTLS (tlsSettings, runTLS)
import System.Log.Handler (setFormatter)
import System.Log.Handler.Simple (fileHandler)
import System.Log.Logger ( debugM, errorM, setLevel, updateGlobalLogger
                         , noticeM, Priority(..), addHandler)
import System.Log.Formatter (simpleLogFormatter)

import Text.Read (readMaybe)

import Version (apiV3Reply, apiVersions)
import Web.Scotty.Internal.Types (ActionT(..))

import qualified Auth as A
import qualified Common.Database as CD
import qualified Data.Text.Lazy as TL
import qualified Database.MongoDB as M
import qualified Domain as D
import qualified Error as E
import qualified Model.Assignment as MA
import qualified Model.Domain as MD
import qualified Model.Project as MP
import qualified Model.Role as MR
import qualified Model.Service as MS
import qualified Model.Token as MT
import qualified Model.User as MU
import qualified Project as P
import qualified Role as R
import qualified Service as Srv
import qualified User as U
import qualified Web.Scotty.Trans as S

main = do
  config <- readConfig
  updateGlobalLogger loggerName $ setLevel $ logLevel config
  fh <- fileHandler "keystone.log" DEBUG
  updateGlobalLogger loggerName $ addHandler $ setFormatter fh (simpleLogFormatter "$utcTime (pid $pid, $tid) $prio: $msg")

  !policy <- A.loadPolicy -- bang pattern is because we want to know if the policy is correct now
  let authGuard = A.requireToken config
  verifyDatabase $ database config

  app <- S.scottyAppT id id (application config)
  let settings = tlsSettings
                      (certificateFile config)
                      (keyFile config)
  let serverSettings = setPort (port config) defaultSettings
  liftIO $ noticeM loggerName "Starting web server"
  case serverType config of
    Tls   -> runTLS settings serverSettings app
    Plain -> runSettings serverSettings app

application :: KeystoneConfig
            -> ScottyM ()
application config = do
  --S.middleware (withAuth config)
  S.defaultHandler $ \e -> do
    S.status $ E.code e
    case statusCode $ E.code e of
      500 -> do
        time <- liftIO $ getCurrentTime
        liftIO $ errorM loggerName $ E.message e
        S.json $ e {E.message = "Internal error. Server time - " ++ (show time)}
      _ -> do
        S.json e
  S.get "/" $ do
    with_host_url config apiVersions
  S.get "/v3" $ do
    with_host_url config apiV3Reply
  -- Token API
  S.post "/v3/auth/tokens" $ do
    (au :: A.AuthRequest) <- parseRequest
    liftIO $ debugM loggerName $ show au
    baseUrl <- getBaseUrl config
    runResourceT $ do
      (releaseKey, pipe) <- allocate (CD.connect $ database config) M.close
      res <- liftIO $ mapM (A.authenticate (A.scope au) pipe) (A.methods au)
      release releaseKey
      case head res of
        Right (tokenId, t) -> lift $ do
          let resp = A.produceTokenResponse t baseUrl
          S.json resp
          S.addHeader "X-Subject-Token" (TL.pack tokenId)
          S.status status200
        Left errorMessage -> lift $ do
          S.json $ E.unauthorized errorMessage
          S.status status401
  S.addroute GET "/v3/auth/tokens" $ A.requireToken config $ \token -> do
    mSubjectToken <- S.header hXSubjectToken
    baseUrl <- getBaseUrl config
    res <- runResourceT $ do
      (releaseKey, pipe) <- allocate (CD.connect $ database config) M.close
      runExceptT $ do
        when (isNothing mSubjectToken) $ throwError "Could not find token, ."
        let mst = readMaybe $ TL.unpack $ fromJust mSubjectToken

        when (isNothing mst) $ throwError "Token is not an object id"
        let st = fromJust mst
        mToken <- liftIO $ CD.runDB pipe $ MT.findTokenById st

        when (isNothing mToken) $ throwError $ "Could not find token, " ++ (show st) ++ "."
        let token = fromJust mToken
        currentTime <- liftIO getCurrentTime

        when (currentTime > (MT.expiresAt token)) $ throwError $ "Could not find token, " ++ (show st) ++ "."
        lift $ release releaseKey
        return $ A.produceTokenResponse token baseUrl

    case res of
      Left errorMessage -> do
        S.status status404
        S.json $ E.notFound errorMessage
      Right resp -> do
        S.status status200
        S.json resp
  S.addroute HEAD "/v3/auth/tokens" $ A.requireToken config $ \token -> do
    mSubjectToken <- S.header hXSubjectToken
    res <- runMaybeT $ do
      subjectToken <- MaybeT $ return mSubjectToken
      st <- MaybeT $ return $ readMaybe $ TL.unpack subjectToken
      isValid <- liftIO $ CD.withDB (database config) $ MT.validateToken st
      when (not isValid) mzero
      return st

    case res of
      Nothing -> do
        S.status status404
      Just _ -> do
        S.status status204
  -- Service API
  S.post "/v3/services" $ A.requireToken config $ \token -> do
    (scr :: Srv.ServiceCreateRequest) <- parseRequest
    service <- liftIO $ Srv.newRequestToService scr
    sid <- liftIO $ CD.withDB (database config) $ MS.createService service
    S.status status201
    with_host_url config $ MS.produceServiceReply service
  S.get "/v3/services" $ A.requireToken config $ \token -> do
    serviceName <- parseMaybeString "name"
    services <- liftIO $ CD.withDB (database config) $ MS.listServices serviceName
    S.status status200
    with_host_url config $ MS.produceServicesReply services
  S.get "/v3/services/:sid" $ A.requireToken config $ \token -> do
    (sid :: M.ObjectId) <- parseId "sid"
    mService <- liftIO $ CD.withDB (database config) $ MS.findServiceById sid
    case mService of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "Service not found"
      Just service -> do
        S.status status200
        with_host_url config $ MS.produceServiceReply service
  S.patch "/v3/services/:sid" $ A.requireToken config $ \token -> do
    (sid :: M.ObjectId) <- parseId "sid"
    (sur :: Srv.ServiceUpdateRequest) <- parseRequest
    mService <- liftIO $ CD.withDB (database config) $ MS.updateService sid (Srv.updateRequestToDocument sur)
    case mService of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "Service not found"
      Just service -> do
        S.status status200
        with_host_url config $ MS.produceServiceReply service
  S.delete "/v3/services/:sid" $ A.requireToken config $ \token -> do
    (sid :: M.ObjectId) <- parseId "sid"
    n <- liftIO $ CD.withDB (database config) $ MS.deleteService sid
    case n of
      NotFound -> do
        S.json $ E.notFound $ "Could not find service, " ++ (show sid) ++ "."
        S.status status404
      Success -> S.status status204
  --- Endpoint API
  S.post "/v3/endpoints" $ A.requireToken config $ \token -> do
    (ecr :: Srv.EndpointCreateRequest) <- parseRequest
    endpoint <- liftIO $ Srv.newRequestToEndpoint ecr
    mEid <- liftIO $ CD.withDB (database config) $ MS.addEndpoint (Srv.eserviceId ecr) endpoint
    case mEid of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "Service not found"
      Just _eid -> do
        S.status status201
        with_host_url config $ MS.produceEndpointReply endpoint (Srv.eserviceId ecr)
  S.get "/v3/endpoints" $ A.requireToken config $ \token -> do
    endpoints <- liftIO $ CD.withDB (database config) $ MS.listEndpoints
    S.status status200
    with_host_url config $ MS.produceEndpointsReply endpoints
  -- Domain API
  S.get "/v3/domains" $ A.requireToken config $ \token -> do
    S.status status200
    with_host_url config $ D.produceDomainsReply []
  S.get "/v3/domains/:did" $ A.requireToken config $ \token -> do
    (did :: M.ObjectId) <- parseId "did"
    S.status status200
    with_host_url config $ D.produceDomainReply MD.Domain
  -- Project API
  S.post "/v3/projects" $ A.requireToken config $ \token -> do
    (pcr :: P.ProjectCreateRequest) <- parseRequest
    project <- liftIO $ P.newRequestToProject pcr
    mPid <- liftIO $ CD.withDB (database config) $ MP.createProject project
    case mPid of
      Left err -> do
        S.json err
        S.status $ E.code err
      Right rid -> do
        S.status status201
        with_host_url config $ MP.produceProjectReply project
  S.get "/v3/projects" $ A.requireToken config $ \token -> do
    projectName <- parseMaybeString "name"
    projects <- liftIO $ CD.withDB (database config) $ MP.listProjects projectName
    S.status status200
    with_host_url config $ MP.produceProjectsReply projects
  S.get "/v3/projects/:pid" $ A.requireToken config $ \token -> do
    (pid :: M.ObjectId) <- parseId "pid"
    mProject <- liftIO $ CD.withDB (database config) $ MP.findProjectById pid
    case mProject of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "Project not found"
      Just project -> do
        S.status status200
        with_host_url config $ MP.produceProjectReply project
  S.get "/v3/projects/:pid/users/:uid/roles" $ A.requireToken config $ \token -> do
    (pid :: M.ObjectId) <- parseId "pid"
    (uid :: M.ObjectId) <- parseId "uid"
    roles <- liftIO $ CD.withDB (database config) $ MA.listUserRoles (MP.ProjectId pid) (MU.UserId uid)
    S.status status200
    with_host_url config $ MR.produceRolesReply roles -- TODO base url should be revised here
  S.put "/v3/projects/:pid/users/:uid/roles/:rid" $ A.requireToken config $ \token -> do
    (pid :: M.ObjectId) <- parseId "pid"
    (uid :: M.ObjectId) <- parseId "uid"
    (rid :: M.ObjectId) <- parseId "rid"
    res <- liftIO $ CD.withDB (database config) $ MA.addAssignment (MA.Assignment (MP.ProjectId pid) (MU.UserId uid) (MR.RoleId rid))
    S.status status204
  -- User API
  S.post "/v3/users" $ A.requireToken config $ \token -> do
    (d :: U.UserCreateRequest) <- parseRequest
    user <- liftIO $ U.newRequestToUser d
    mUid <- liftIO $ CD.withDB (database config) $ MU.createUser user
    case mUid of
      Left err -> do
        S.json err
        S.status $ E.code err
      Right rid -> do
        S.status status201
        with_host_url config $ MU.produceUserReply user
  S.get "/v3/users" $ A.requireToken config $ \token -> do
    userName <- parseMaybeString "name"
    users <- liftIO $ CD.withDB (database config) $ MU.listUsers userName
    S.status status200
    with_host_url config $ MU.produceUsersReply users
  S.get "/v3/users/:uid" $ A.requireToken config $ \token -> do
    (uid :: M.ObjectId) <- parseId "uid"
    mUser <- liftIO $ CD.withDB (database config) $ MU.findUserById uid
    case mUser of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "User not found"
      Just user -> do
        S.status status200
        with_host_url config $ MU.produceUserReply user
  S.patch "/v3/users/:uid" $ A.requireToken config $ \token -> do
    (uid :: M.ObjectId) <- parseId "uid"
    (uur :: U.UserUpdateRequest) <- parseRequest
    mUser <- liftIO $ CD.withDB (database config) $ MU.updateUser uid (U.updateRequestToDocument uur)
    case mUser of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "User not found"
      Just user -> do
        S.status status200
        with_host_url config $ MU.produceUserReply user
  S.delete "/v3/users/:uid" $ A.requireToken config $ \token -> do
    (uid :: M.ObjectId) <- parseId "uid"
    st <- liftIO $ CD.withDB (database config) $ MU.deleteUser uid
    case st of
      Success  -> S.status status204
      NotFound -> do
        S.json $ E.notFound $ "Could not find user, " ++ (show uid) ++ "."
        S.status status404
      Busy     -> do
        S.json $ E.conflict $ "The user " ++ (show uid) ++ " has a role assigned. Please remove the role assignment first."
        S.status status409
  -- Role API
  S.post "/v3/roles" $ A.requireToken config $ \token -> do
    (rcr :: R.RoleCreateRequest) <- parseRequest
    role <- liftIO $ R.newRequestToRole rcr
    mRid <- liftIO $ liftIO $ CD.withDB (database config) $ MR.createRole role
    case mRid of
      Left err -> do
        S.json err
        S.status $ E.code err
      Right rid -> do
        S.status status201
        with_host_url config $ MR.produceRoleReply role
  S.get "/v3/roles" $ A.requireToken config $ \token -> do
    roleName <- parseMaybeString "name"
    roles <- liftIO $ CD.withDB (database config) $ MR.listRoles roleName
    S.status status200
    with_host_url config $ MR.produceRolesReply roles
  S.get "/v3/roles/:rid" $ A.requireToken config $ \token -> do
    (rid :: M.ObjectId) <- parseId "rid"
    mRole <- liftIO $ CD.withDB (database config) $ MR.findRoleById rid
    case mRole of
      Nothing -> do
        S.status status404
        S.json $ E.notFound "Role not found"
      Just role -> do
        S.status status200
        with_host_url config $ MR.produceRoleReply role
  S.get "/v3/role_assignments" $ A.requireToken config $ \token -> do
    userId <- parseMaybeParam "user.id"
    projectId <- parseMaybeParam "scope.project.id"
    roles <- liftIO $ CD.withDB (database config) $ MA.listAssignments (MP.ProjectId <$> projectId) (MU.UserId <$> userId)
    S.status status200
    with_host_url config $ MA.produceAssignmentsReply roles -- TODO base url should be revised here

parseMaybeString :: TL.Text -> ActionM (Maybe String)
parseMaybeString paramName =
  (flip S.rescue) (\msg -> return Nothing) $ do
    (value :: String) <- S.param paramName
    return $ Just value

parseMaybeParam :: Read a => TL.Text -> ActionM (Maybe a)
parseMaybeParam paramName =
  (flip S.rescue) (\msg -> return Nothing) $ do
    (value :: String) <- S.param paramName
    case readMaybe value of
      Nothing -> S.raise $ E.badRequest $ "Failed to parse value from " ++ (TL.unpack paramName)
      Just v  -> return $ Just v

parseId :: Read a => TL.Text -> ActionM a
parseId paramName = do
  s <- S.param paramName
  case readMaybe s of
    Nothing -> S.raise $ E.badRequest $ "Failed to parse ObjectId from " ++ (TL.unpack paramName)
    Just v  -> return v

parseRequest :: FromJSON a => ActionM a
parseRequest = do
  S.rescue S.jsonData $ \e ->
    S.raise $ E.badRequest $ E.message e

hXSubjectToken :: TL.Text
hXSubjectToken = "X-Subject-Token"

host_url :: ServerType -> ActionM (Maybe String)
host_url st = do
  mh <- S.header "host"
  let protocol =
          case st of
            Plain -> "http"
            Tls   -> "https"
  return $ fmap (\h -> protocol ++ "://" ++ (TL.unpack h)) mh

getBaseUrl :: KeystoneConfig -> ActionM String
getBaseUrl config = do
  case endpoint config of
    Just e -> return e
    Nothing -> do
      mh <- host_url $ serverType config
      case mh of
        Just h -> return h
        Nothing -> S.raise $ E.badRequest "Host header is required or endpoint should be set"

with_host_url :: KeystoneConfig -> (String -> Value) -> ActionM ()
with_host_url config v = do
  url <- getBaseUrl config
  S.json $ v url

verifyDatabase :: Database -> IO ()
verifyDatabase dbConf = liftIO $ CD.withDB dbConf $ do
  liftIO $ noticeM loggerName "Verifying user collection"
  MU.verifyDatabase
  liftIO $ noticeM loggerName "Verifying role collection"
  MR.verifyDatabase
  liftIO $ noticeM loggerName "Verifying project collection"
  MP.verifyDatabase
  liftIO $ noticeM loggerName "Verifying token collection"
  MT.verifyDatabase
