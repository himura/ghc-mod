{-# LANGUAGE OverloadedStrings #-}

module Cabal (initializeGHC) where

import Control.Applicative
import Control.Exception
import Control.Monad
import CoreMonad
import Data.List
import Data.Maybe
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse (readPackageDescription)
import Distribution.Verbosity (silent)
import ErrMsg
import GHC
import GHCApi
import Language.Haskell.Extension
import System.Directory
import System.FilePath
import Types

----------------------------------------------------------------

importDirs :: [String]
importDirs = [".","..","../..","../../..","../../../..","../../../../.."]

initializeGHC :: Options -> FilePath -> [String] -> Bool -> Ghc (FilePath,LogReader)
initializeGHC opt fileName ghcOptions logging =
    withCabal `gcatch` withoutCabal
  where
    withoutCabal :: SomeException -> Ghc (FilePath,LogReader)
    withoutCabal _ = do
        logReader <- initSession opt ghcOptions importDirs logging
        return (fileName,logReader)
    withCabal = do
        (owdir,cdir,cfile) <- liftIO getDirs
        binfo <- parseCabalFile cfile
        let (idirs',exts',mlang) = extractBuildInfo binfo
            exts = map addX exts'
            lang = maybe "-XHaskell98" addX mlang
            gopts = ghcOptions ++ exts ++ [lang]
        changeToCabalDirectory cdir
        let idirs = case idirs' of
                []   -> [cdir,owdir]
                dirs -> dirs ++ [owdir]
            file = ajustFileName fileName owdir cdir
        logReader <- initSession opt gopts idirs logging
        return (file,logReader)
    addX x = "-X" ++ show x

----------------------------------------------------------------

-- Causes error, catched in the upper function.
parseCabalFile :: FilePath -> Ghc BuildInfo
parseCabalFile file = do
    cabal <- liftIO $ readPackageDescription silent file
    return . fromJust $ fromLibrary cabal >> fromExecutable cabal
  where
    fromLibrary c     = libBuildInfo . condTreeData <$> condLibrary c
    fromExecutable c  = buildInfo . condTreeData . snd <$> toMaybe (condExecutables c)
    toMaybe [] = Nothing
    toMaybe (x:_) = Just x

-- SourceDirs, Extensions, and Language
extractBuildInfo :: BuildInfo -> ([String],[Extension],Maybe Language)
extractBuildInfo binfo = (hsSourceDirs binfo
                         ,oldExtensions binfo
                         ,defaultLanguage binfo)

----------------------------------------------------------------

ajustFileName :: FilePath -> FilePath -> FilePath -> FilePath
ajustFileName name olddir newdir
  | olen == nlen = name
  | otherwise    = drop (nlen+1) olddir </> name
  where
    olen = length olddir
    nlen = length newdir

changeToCabalDirectory :: FilePath -> Ghc ()
changeToCabalDirectory dir = do
    liftIO $ setCurrentDirectory dir
    workingDirectoryChanged

-- CurrentWorkingDir, CabalDir, CabalFile
getDirs :: IO (FilePath,FilePath,FilePath)
getDirs = do
    wdir <- getCurrentDirectory
    (cdir,cfile) <- cabalDir wdir
    return (wdir,cdir,cfile)

-- Causes error, catched in the upper function.
-- CabalDir, CabalFile
cabalDir :: FilePath -> IO (FilePath,FilePath)
cabalDir dir = do
    cnts <- (filter isCabal <$> getDirectoryContents dir)
            >>= filterM (\file -> doesFileExist (dir </> file))
    let dir' = takeDirectory dir
    case cnts of
        [] | dir' == dir -> throwIO $ userError "No cabal file"
           | otherwise   -> cabalDir dir'
        cfile:_          -> return (dir,dir </> cfile)
  where
    isCabal name = ".cabal" `isSuffixOf` name && length name > 6
