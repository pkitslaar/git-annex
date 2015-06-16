{- git-annex JSON output
 -
 - Copyright 2011 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Messages.JSON (
	start,
	end,
	note,
	add,
	complete,
	DualDisp(..),
) where

import Text.JSON

import qualified Utility.JSONStream as Stream

start :: String -> Maybe String -> IO ()
start command file =
	putStr $ Stream.start $ ("command", command) : filepart file
  where
	filepart Nothing = []
	filepart (Just f) = [("file", f)]

end :: Bool -> IO ()
end b = putStr $ Stream.add [("success", b)] ++ Stream.end

note :: String -> IO ()
note s = add [("note", s)]

add :: JSON a => [(String, a)] -> IO ()
add v = putStr $ Stream.add v

complete :: JSON a => [(String, a)] -> IO ()
complete v = putStr $ Stream.start v ++ Stream.end

-- A value that can be displayed either normally, or as JSON.
data DualDisp = DualDisp
	{ dispNormal :: String
	, dispJson :: String
	}

instance JSON DualDisp where
	showJSON = JSString . toJSString . dispJson
	readJSON _ = Error "stub"

instance Show DualDisp where
	show = dispNormal
