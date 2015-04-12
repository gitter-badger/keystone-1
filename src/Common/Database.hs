{-# LANGUAGE OverloadedStrings #-}
module Common.Database
where

import Common (loggerName)
import Config (Database(..))
import Control.Monad.IO.Class (MonadIO(..))
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Typeable (typeOf)
import System.IO.Error ( catchIOError, ioError, userError
                       , ioeGetErrorType, ioeGetLocation, ioeGetErrorString)
import System.Log.Logger (errorM)

import qualified Database.MongoDB as M

dbName :: Text
dbName = "keystone"

verifyDatabase :: Database -> IO ()
verifyDatabase dbConf = return ()

connect :: MonadIO m => Database -> m M.Pipe
connect dbConf = liftIO $ do
  catchIOError (M.connect $ M.Host host $ M.PortNumber $ fromIntegral port) $ \e -> do
    let t = typeOf e
    errorM loggerName $ "Can't connect to the database: " ++ (ioeGetErrorString e)
    time <- getCurrentTime
    ioError $ userError $ "Internal error at server time - " ++ (show time)
  where
    host = dbHost dbConf
    port = dbPort dbConf

runDB :: MonadIO m => M.Pipe -> M.Action m a -> m a
runDB p f = M.access p M.master dbName f
