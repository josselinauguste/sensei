{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Data.Time
import Sensei.App
import Sensei.CLI
import Sensei.Wrapper
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.Posix.User

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  homeDir <- getHomeDirectory
  currentDir <- getCurrentDirectory
  prog <- getProgName
  progArgs <- getArgs
  st <- getCurrentTime
  curUser <- getLoginName

  case prog of
    "git" -> wrapProg "/usr/bin/git" progArgs st currentDir
    "stak" -> wrapProg (homeDir </> ".local/bin/stack") progArgs st currentDir
    "docker" -> wrapProg "/usr/local/bin/docker" progArgs st currentDir
    "ep" -> do
      opts <- parseSenseiOptions
      recordFlow opts curUser st currentDir
    "sensei-exe" -> startServer
    _ -> hPutStrLn stderr ("Don't know how to handle program " <> prog) >> exitWith (ExitFailure 1)
