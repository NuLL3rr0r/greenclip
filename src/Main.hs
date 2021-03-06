{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Main where

import           ClassyPrelude      as CP hiding (readFile)
import           Data.Binary        (decode, encode)
import qualified Data.Text          as T
import qualified Data.Vector        as V
import           Lens.Micro
import           Lens.Micro.Mtl
import qualified Clipboard   as Clip
import qualified System.Directory   as Dir
import           System.Environment (lookupEnv)
import           System.IO          (IOMode (..), openFile)
import           System.Timeout     (timeout)


data Command = DAEMON | PRINT | COPY Text | CLEAR | HELP deriving (Show, Read)

data Config = Config
  { maxHistoryLength           :: Int
  , historyPath                :: String
  , staticHistoryPath          :: String
  , usePrimarySelectionAsInput :: Bool
  } deriving (Show, Read)

type ClipHistory = Vector Text

readFile :: FilePath -> IO ByteString
readFile filepath = bracket (openFile filepath ReadMode) hClose $ \h -> do
  str <- hGetContents h
  let !str' = str
  return str'


getHistory :: (MonadIO m, MonadReader Config m) => m ClipHistory
getHistory = do
  storePath <- view (to historyPath)
  liftIO $ readH storePath `catchAnyDeep` const mempty
  where
    readH filePath = readFile filePath <&> fromList . decode . fromStrict

getStaticHistory :: (MonadIO m, MonadReader Config m) => m ClipHistory
getStaticHistory = do
  storePath <- view (to staticHistoryPath)
  liftIO $ readH storePath `catchAnyDeep` const mempty
  where
    readH filePath = readFile filePath <&> fromList . T.lines . decodeUtf8


storeHistory :: (MonadIO m, MonadReader Config m) => ClipHistory -> m ()
storeHistory history = do
  storePath <- view (to historyPath)
  liftIO $ writeH storePath history `catchAnyDeep` const mempty
  where
    writeH storePath = writeFile storePath . toStrict . encode . toList

appendToHistory :: (MonadIO m, MonadReader Config m) => Text -> ClipHistory -> m ClipHistory
appendToHistory sel history =
  let selection = T.strip sel in
  if selection == mempty || selection == fromMaybe mempty (headMay history)
  then return history
  else do
    maxLen <- view (to maxHistoryLength)
    return $ fst . V.splitAt maxLen . cons selection $ filter (/= selection) history


runDaemon :: (MonadIO m, MonadReader Config m, MonadCatch m) => m ()
runDaemon = do
  usePrimary <- view (to usePrimarySelectionAsInput)
  let getSelections = (getSelectionFrom Clip.getClipboardString, mempty)
                    : [(getSelectionFrom Clip.getPrimaryClipboard, mempty) | usePrimary]
  forever $ (getHistory >>= go getSelections) `catchAnyDeep` handleError

  where
    _0_5sec :: Int
    _0_5sec = 5 * 10^(5::Int)

    getSelection [] = return ([], mempty)
    getSelection ((getSel, lastSel):getSels) = do
      selection <- liftIO getSel
      if selection /= lastSel
         then return ((getSel, selection) : getSels, selection)
         else getSelection getSels >>= \(e, selection) -> return ((getSel, lastSel) : e, selection)

    go getSelections history = do
      (getSelections', selection) <- liftIO $ getSelection getSelections
      history' <- appendToHistory selection history
      when (history' /= history) (storeHistory history')

      liftIO $ threadDelay _0_5sec
      go getSelections' history'

    getSelectionFrom fn = timeout 1000000 fn <&> T.pack . fromMaybe mempty . join

    handleError ex = do
      let displayMissing = "openDisplay" `T.isInfixOf` tshow ex
      if displayMissing
      then error "X display not available. Please start Xorg before running greenclip"
      else sayErrShow ex


toRofiStr :: Text -> Text
toRofiStr = T.map (\c -> if c == '\n' || c == '\r' then '\xA0' else c)

fromRofiStr :: Text -> Text
fromRofiStr = T.map (\c -> if c == '\xA0' then '\n' else c)

printHistoryForRofi :: (MonadIO m, MonadReader Config m) => m ()
printHistoryForRofi = do
  history <- mappend <$> getHistory <*> getStaticHistory
  _ <- traverse (putStrLn . toRofiStr) history
  return ()

advertiseSelection :: Text -> IO ()
advertiseSelection = Clip.setClipboardString . T.unpack . fromRofiStr

getConfig :: IO Config
getConfig = do
  home <- Dir.getHomeDirectory
  let cfgPath = home </> ".config/greenclip.cfg"

  cfgStr <- (readFile cfgPath <&> T.strip . decodeUtf8) `catchAnyDeep` const mempty
  let cfg = fromMaybe (defaultConfig home) (readMay cfgStr)

  writeFile cfgPath (fromString $ show cfg)
  return cfg

  where
    defaultConfig home = Config 25 (home </> ".cache/greenclip.history") (home </> ".cache/greenclip.staticHistory") False


parseArgs :: [Text] -> Command
parseArgs ("daemon":_)   = DAEMON
parseArgs ["clear"]      = CLEAR
parseArgs ["print"]      = PRINT
parseArgs ["print", sel] = COPY sel
parseArgs _              = HELP

run :: Command -> IO ()
run cmd = do
  cfg <- getConfig
  case cmd of
    DAEMON   -> runReaderT runDaemon cfg
    PRINT    -> runReaderT printHistoryForRofi cfg
    CLEAR    -> runReaderT (storeHistory mempty) cfg
    -- Should rename COPY into ADVERTISE but as greenclip is already used I don't want to break configs
    -- of other people
    COPY sel -> advertiseSelection sel
    HELP     -> putStrLn $ "greenclip v2.0 -- Recyle your clipboard selections\n\n" <>
                           "Available commands\n" <>
                           "daemon: Spawn the daemon that will listen to selections\n" <>
                           "print:  Display all selections history\n" <>
                           "clear:  Clear history\n" <>
                           "help:   Display this message\n"

main :: IO ()
main = do
  displayPresent <- lookupEnv "DISPLAY"
  case displayPresent of
    Nothing -> putStrLn "X display not available. Please start Xorg before running greenclip"
    _       -> getArgs >>= run .parseArgs
