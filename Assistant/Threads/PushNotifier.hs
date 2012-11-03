{- git-annex assistant push notification thread, using XMPP
 -
 - This handles both sending outgoing push notifications, and receiving
 - incoming push notifications.
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Threads.PushNotifier where

import Assistant.Common
import Assistant.XMPP
import Assistant.XMPP.Client
import Assistant.Pushes
import Assistant.Types.Buddies
import Assistant.XMPP.Buddies
import Assistant.Sync
import Assistant.DaemonStatus
import qualified Remote
import Utility.ThreadScheduler

import Network.Protocol.XMPP
import Control.Concurrent
import qualified Data.Set as S
import qualified Git.Branch
import Data.Time.Clock

pushNotifierThread :: NamedThread
pushNotifierThread = NamedThread "PushNotifier" $ do
	iodebug <- asIO1 debug
	iopull <- asIO1 pull
	iowaitpush <- asIO waitPush
	ioupdatebuddies <- asIO1 $ \p -> do
		updateBuddyList (updateBuddies p) <<~ buddyList
		debug =<< map show <$> getBuddyList <<~ buddyList
	ioemptybuddies <- asIO $
		updateBuddyList (const noBuddies) <<~ buddyList
	ioclient <- asIO $
		xmppClient iowaitpush iodebug iopull ioupdatebuddies ioemptybuddies
	forever $ do
		tid <- liftIO $ forkIO ioclient
		waitRestart
		liftIO $ killThread tid

xmppClient
	:: (IO [UUID])
	-> ([String] -> IO ()) 
	-> ([UUID] -> IO ()) 
	-> (Presence -> IO ())
	-> IO ()
	-> Assistant ()
xmppClient iowaitpush iodebug iopull ioupdatebuddies ioemptybuddies = do
	v <- liftAnnex getXMPPCreds
	case v of
		Nothing -> noop
		Just c -> liftIO $ loop c =<< getCurrentTime
  where
	loop c starttime = do
		void $ connectXMPP c $ \jid -> do
			fulljid <- bindJID jid
			liftIO $ iodebug ["XMPP connected", show fulljid]
			{- The buddy list starts empty each time the client
			 - connects, so that stale info is not retained. -}
			liftIO ioemptybuddies
			putStanza $ gitAnnexPresence gitAnnexSignature
			s <- getSession
			_ <- liftIO $ forkIO $ void $ runXMPP s $
				receivenotifications fulljid
			sendnotifications
		now <- getCurrentTime
		if diffUTCTime now starttime > 300
			then do
				iodebug ["XMPP connection lost; reconnecting"]
				loop c now
			else do
				iodebug ["XMPP connection failed; will retry"]
				threadDelaySeconds (Seconds 300)
				loop c =<< getCurrentTime
	sendnotifications = forever $ do
		us <- liftIO iowaitpush
		putStanza $ gitAnnexPresence $ encodePushNotification us
	receivenotifications fulljid = forever $ do
		s <- getStanza
		liftIO $ iodebug ["received XMPP:", show s]
		case s of
			ReceivedPresence p@(Presence { presenceFrom = from })
				| from == Just fulljid -> noop
				| otherwise -> do
					liftIO $ ioupdatebuddies p
					when (isGitAnnexPresence p) $
						liftIO $ iopull $ concat $ catMaybes $
							map decodePushNotification $
								presencePayloads p
			_ -> noop

{- We only pull from one remote out of the set listed in the push
 - notification, as an optimisation.
 -
 - Note that it might be possible (though very unlikely) for the push
 - notification to take a while to be sent, and multiple pushes happen
 - before it is sent, so it includes multiple remotes that were pushed
 - to at different times. 
 -
 - It could then be the case that the remote we choose had the earlier
 - push sent to it, but then failed to get the later push, and so is not
 - fully up-to-date. If that happens, the pushRetryThread will come along
 - and retry the push, and we'll get another notification once it succeeds,
 - and pull again. -}
pull :: [UUID] -> Assistant ()
pull [] = noop
pull us = do
	rs <- filter matching . syncRemotes <$> getDaemonStatus
	debug $ "push notification for" : map (fromUUID . Remote.uuid ) rs
	pullone rs =<< liftAnnex (inRepo Git.Branch.current)
  where
	matching r = Remote.uuid r `S.member` s
	s = S.fromList us

	pullone [] _ = noop
	pullone (r:rs) branch =
		unlessM (all id . fst <$> manualPull branch [r]) $
			pullone rs branch
