{- git-annex Messages data types
 - 
 - Copyright 2012 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Types.Messages where

import Data.Default

#ifdef WITH_CONCURRENTOUTPUT
import System.Console.Regions (ConsoleRegion)
#endif

data OutputType = NormalOutput | QuietOutput | ConcurrentOutput Int | JSONOutput
	deriving (Show)

data SideActionBlock = NoBlock | StartBlock | InBlock
	deriving (Eq)

data MessageState = MessageState
	{ outputType :: OutputType
	, sideActionBlock :: SideActionBlock
#ifdef WITH_CONCURRENTOUTPUT
	, consoleRegion :: Maybe ConsoleRegion
	, consoleRegionErrFlag :: Bool
#endif
	}

instance Default MessageState
  where
	def = MessageState
		{ outputType = NormalOutput
		, sideActionBlock = NoBlock
#ifdef WITH_CONCURRENTOUTPUT
		, consoleRegion = Nothing
		, consoleRegionErrFlag = False
#endif
		}
