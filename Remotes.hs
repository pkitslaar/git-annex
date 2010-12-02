{- git-annex remote repositories
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Remotes (
	list,
	keyPossibilities,
	tryGitConfigRead,
	inAnnex,
	same,
	commandLineRemote,
	copyFromRemote,
	copyToRemote,
	runCmd
) where

import Control.Exception.Extensible
import Control.Monad.State (liftIO)
import qualified Data.Map as Map
import Data.String.Utils
import System.Directory hiding (copyFile)
import System.Posix.Directory
import Data.List
import Control.Monad (when, unless, filterM)

import Types
import qualified GitRepo as Git
import qualified Annex
import LocationLog
import Locations
import UUID
import Utility
import qualified Core
import Messages
import CopyFile
import qualified SysConfig

{- Human visible list of remotes. -}
list :: [Git.Repo] -> String
list remotes = join ", " $ map Git.repoDescribe remotes 

{- Cost ordered list of remotes that the LocationLog indicate may have a key. -}
keyPossibilities :: Key -> Annex [Git.Repo]
keyPossibilities key = do
	g <- Annex.gitRepo
	uuids <- liftIO $ keyLocations g key
	allremotes <- remotesByCost
	-- To determine if a remote has a key, its UUID needs to be known.
	-- The locally cached UUIDs of remotes can fall out of date if
	-- eg, a different drive is mounted at the same location.
	-- But, reading the config of remotes can be expensive, so make
	-- sure we only do it once per git-annex run.
	remotesread <- Annex.flagIsSet "remotesread"
	if remotesread
		then reposByUUID allremotes uuids
		else do
			-- We assume that it's cheap to read the config
			-- of non-URL remotes, so that is done each time.
			-- But reading the config of an URL remote is
			-- only done when there is no cached UUID value.
			let cheap = filter (not . Git.repoIsUrl) allremotes
			let expensive = filter Git.repoIsUrl allremotes
			doexpensive <- filterM cachedUUID expensive
			unless (null doexpensive) $
				showNote $ "getting UUID for " ++
					list doexpensive ++ "..."
			let todo = cheap ++ doexpensive
			if not $ null todo
				then do
					_ <- mapM tryGitConfigRead todo
					Annex.flagChange "remotesread" $ FlagBool True
					keyPossibilities key
				else reposByUUID allremotes uuids
	where
		cachedUUID r = do
			u <- getUUID r
			return $ null u 

{- Checks if a given remote has the content for a key inAnnex.
 - If the remote cannot be accessed, returns a Left error.
 -}
inAnnex :: Git.Repo -> Key -> Annex (Either IOException Bool)
inAnnex r key = if Git.repoIsUrl r
		then checkremote
		else liftIO (try checklocal ::IO (Either IOException Bool))
	where
		checklocal = do
			-- run a local check by making an Annex monad
			-- using the remote
			a <- Annex.new r []
			Annex.eval a (Core.inAnnex key)
		checkremote = do
			showNote ("checking " ++ Git.repoDescribe r ++ "...")
			inannex <- runCmd r "test" ["-e", annexLocation r key]
			-- XXX Note that ssh failing and the file not existing
			-- are not currently differentiated.
			return $ Right inannex

{- Cost Ordered list of remotes. -}
remotesByCost :: Annex [Git.Repo]
remotesByCost = do
	g <- Annex.gitRepo
	reposByCost $ Git.remotes g

{- Orders a list of git repos by cost. Throws out ignored ones. -}
reposByCost :: [Git.Repo] -> Annex [Git.Repo]
reposByCost l = do
	notignored <- filterM repoNotIgnored l
	costpairs <- mapM costpair notignored
	return $ fst $ unzip $ sortBy cmpcost costpairs
	where
		costpair r = do
			cost <- repoCost r
			return (r, cost)
		cmpcost (_, c1) (_, c2) = compare c1 c2

{- Calculates cost for a repo.
 -
 - The default cost is 100 for local repositories, and 200 for remote
 - repositories; it can also be configured by remote.<name>.annex-cost
 -}
repoCost :: Git.Repo -> Annex Int
repoCost r = do
	cost <- repoConfig r "cost" ""
	if not $ null cost
		then return $ read cost
		else if Git.repoIsUrl r
			then return 200
			else return 100

{- Checks if a repo should be ignored, based either on annex-ignore
 - setting, or on command-line options. Allows command-line to override
 - annex-ignore. -}
repoNotIgnored :: Git.Repo -> Annex Bool
repoNotIgnored r = do
	ignored <- repoConfig r "ignore" "false"
	fromName <- Annex.flagGet "fromrepository"
	toName <- Annex.flagGet "torepository"
	let name = if null fromName then toName else fromName
	if not $ null name
		then return $ match name
		else return $ not $ Git.configTrue ignored
	where
		match name = name == Git.repoRemoteName r

{- Checks if two repos are the same, by comparing their remote names. -}
same :: Git.Repo -> Git.Repo -> Bool
same a b = Git.repoRemoteName a == Git.repoRemoteName b

{- Returns the remote specified by --from or --to, may fail with error. -}
commandLineRemote :: Annex Git.Repo
commandLineRemote = do
	fromName <- Annex.flagGet "fromrepository"
	toName <- Annex.flagGet "torepository"
	let name = if null fromName then toName else fromName
	when (null name) $ error "no remote specified"
	g <- Annex.gitRepo
	let match = filter (\r -> name == Git.repoRemoteName r) $
		Git.remotes g
	when (null match) $ error $
		"there is no git remote named \"" ++ name ++ "\""
	return $ head match

{- The git configs for the git repo's remotes is not read on startup
 - because reading it may be expensive. This function tries to read the
 - config for a specified remote, and updates state. If successful, it
 - returns the updated git repo. -}
tryGitConfigRead :: Git.Repo -> Annex (Either Git.Repo Git.Repo)
tryGitConfigRead r = do
	sshoptions <- repoConfig r "ssh-options" ""
	if Map.null $ Git.configMap r
		then do
			-- configRead can fail due to IO error or
			-- for other reasons; catch all possible exceptions
			result <- liftIO (try (Git.configRead r $ Just $ words sshoptions)::IO (Either SomeException Git.Repo))
			case result of
				Left _ -> return $ Left r
				Right r' -> do
					g <- Annex.gitRepo
					let l = Git.remotes g
					let g' = Git.remotesAdd g $
						exchange l r'
					Annex.gitRepoChange g'
					return $ Right r'
		else return $ Right r -- config already read
	where 
		exchange [] _ = []
		exchange (old:ls) new =
			if Git.repoRemoteName old == Git.repoRemoteName new
				then new : exchange ls new
				else old : exchange ls new

{- Tries to copy a key's content from a remote to a file. -}
copyFromRemote :: Git.Repo -> Key -> FilePath -> Annex Bool
copyFromRemote r key file
	| not $ Git.repoIsUrl r = getlocal
	| Git.repoIsSsh r = getssh
	| otherwise = error "copying from non-ssh repo not supported"
	where
		keyloc = annexLocation r key
		getlocal = liftIO $ copyFile keyloc file
		getssh = remoteCopyFile r (sshLocation r keyloc) file

{- Tries to copy a key's content to a file on a remote. -}
copyToRemote :: Git.Repo -> Key -> FilePath -> Annex Bool
copyToRemote r key file = do
	g <- Annex.gitRepo
	let keyloc = annexLocation g key
	if not $ Git.repoIsUrl r
		then putlocal keyloc
		else if Git.repoIsSsh r
			then putssh keyloc
			else error "copying to non-ssh repo not supported"
	where
		putlocal src = liftIO $ copyFile src file
		putssh src = remoteCopyFile r src (sshLocation r file)

sshLocation :: Git.Repo -> FilePath -> FilePath
sshLocation r file = Git.urlHost r ++ ":" ++ shellEscape file

{- Copys a file from or to a remote, using rsync (when available) or scp. -}
remoteCopyFile :: Git.Repo -> String -> String -> Annex Bool
remoteCopyFile r src dest = do
	showProgress -- make way for progress bar
	o <- repoConfig r configopt ""
	res <- liftIO $ boolSystem cmd $ options ++ words o ++ [src, dest]
	if res
		then return res
		else do
			when rsync $
				showLongNote "rsync failed -- run git annex again to resume file transfer"
			return res
	where
		cmd
			| rsync = "rsync"
			| otherwise = "scp"
		configopt
			| rsync = "rsync-options"
			| otherwise = "scp-options"
		options
			-- inplace makes rsync resume partial files
			| rsync = ["-p", "--progress", "--inplace"]
			| otherwise = ["-p"]
		rsync = SysConfig.rsync

{- Runs a command in a remote, using ssh if necessary.
 - (Honors annex-ssh-options.) -}
runCmd :: Git.Repo -> String -> [String] -> Annex Bool
runCmd r command params = do
	sshoptions <- repoConfig r "ssh-options" ""
	if not $ Git.repoIsUrl r
		then do
			cwd <- liftIO getCurrentDirectory
			liftIO $ bracket_
				(changeWorkingDirectory (Git.workTree r))
				(changeWorkingDirectory cwd)
				(boolSystem command params)
		else if Git.repoIsSsh r
			then liftIO $ boolSystem "ssh" $
				words sshoptions ++ [Git.urlHost r, sshcmd]
			else error "running command in non-ssh repo not supported"
	where 
		sshcmd = "cd " ++ shellEscape (Git.workTree r) ++
			" && " ++ shellEscape command ++ " " ++
			unwords (map shellEscape params)

{- Looks up a per-remote config option in git config.
 - Failing that, tries looking for a global config option. -}
repoConfig :: Git.Repo -> String -> String -> Annex String
repoConfig r key def = do
	g <- Annex.gitRepo
	let def' = Git.configGet g global def
	return $ Git.configGet g local def'
	where
		local = "remote." ++ Git.repoRemoteName r ++ ".annex-" ++ key
		global = "annex." ++ key
