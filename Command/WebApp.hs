{- git-annex webapp launcher
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.WebApp where

import Common.Annex
import Command
import Assistant
import Utility.WebApp
import Utility.Daemon (checkDaemon)
import qualified Annex
import Option

import Control.Concurrent
import System.Posix.Process

def :: [Command]
def = [withOptions [restartOption] $
        command "webapp" paramNothing seek "launch webapp"]

restartOption :: Option
restartOption = Option.flag [] "restart" "restart the assistant daemon"

seek :: [CommandSeek]
seek = [withFlag restartOption $ \restart -> withNothing $ start restart]

start :: Bool -> CommandStart
start restart = notBareRepo $ do
	f <- liftIO . absPath =<< fromRepo gitAnnexHtmlShim
	ok <- liftIO $ doesFileExist f
	if restart || not ok
		then do
			stopDaemon
			void $ liftIO . catchMaybeIO . removeFile
				=<< fromRepo gitAnnexPidFile
			startassistant
		else do
			r <- checkpid
			when (r == Nothing) $
				startassistant
	let url = "file://" ++ f
	ifM (liftIO $ runBrowser url)
		( stop
		, error $ "failed to start web browser on url " ++ url
		)
	where
		checkpid = do
			pidfile <- fromRepo gitAnnexPidFile
			liftIO $ checkDaemon pidfile
		startassistant = do
			{- Fork a separate process to run the assistant,
			 - with a copy of the Annex state. -}
			state <- Annex.getState id
			liftIO $ void $ forkProcess $
				Annex.eval state $ startDaemon True False
			waitdaemon (100 :: Int)
		waitdaemon 0 = error "failed to start git-annex assistant"
		waitdaemon n = do
			r <- checkpid
			case r of
				Just _ -> return ()
				Nothing -> do
					-- wait 0.1 seconds before retry
					liftIO $ threadDelay 100000
					waitdaemon (n - 1)
