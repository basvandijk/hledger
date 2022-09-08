-- TODO: brick 1 support
-- https://hackage.haskell.org/package/brick-1.0/changelog
{-|
hledger-ui - a hledger add-on providing a curses-style interface.
Copyright (c) 2007-2015 Simon Michael <simon@joyful.com>
Released under GPL version 3 or later.
-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

module Hledger.UI.Main where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (forM_, void, when)
import Data.List (find)
import Data.List.Extra (nubSort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Graphics.Vty (mkVty, Mode (Mouse), Vty (outputIface), Output (setMode))
import Lens.Micro ((^.))
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.FSNotify (Event(Modified), isPollingManager, watchDir, withManager)
import Brick hiding (bsDraw)
import qualified Brick.BChan as BC

import Hledger
import Hledger.Cli hiding (progname,prognameandversion)
import Hledger.UI.Theme
import Hledger.UI.UIOptions
import Hledger.UI.UITypes
import Hledger.UI.UIState (uiState, getDepth)
import Hledger.UI.UIUtils (dlogUiTrace)
import Hledger.UI.MenuScreen
import Hledger.UI.AccountsScreen
import Hledger.UI.BalancesheetScreen
import Hledger.UI.RegisterScreen
import Hledger.UI.TransactionScreen
import Hledger.UI.ErrorScreen

----------------------------------------------------------------------

newChan :: IO (BC.BChan a)
newChan = BC.newBChan 10

writeChan :: BC.BChan a -> a -> IO ()
writeChan = BC.writeBChan


main :: IO ()
main = do
  opts@UIOpts{uoCliOpts=copts@CliOpts{inputopts_=iopts,rawopts_=rawopts}} <- getHledgerUIOpts
  -- when (debug_ $ cliopts_ opts) $ printf "%s\n" prognameandversion >> printf "opts: %s\n" (show opts)

  -- always generate forecasted periodic transactions; their visibility will be toggled by the UI.
  let copts' = copts{inputopts_=iopts{forecast_=forecast_ iopts <|> Just nulldatespan}}

  case True of
    _ | "help"            `inRawOpts` rawopts -> putStr (showModeUsage uimode)
    _ | "info"            `inRawOpts` rawopts -> runInfoForTopic "hledger-ui" Nothing
    _ | "man"             `inRawOpts` rawopts -> runManForTopic  "hledger-ui" Nothing
    _ | "version"         `inRawOpts` rawopts -> putStrLn prognameandversion
    -- _ | "binary-filename" `inRawOpts` rawopts -> putStrLn (binaryfilename progname)
    _                                         -> withJournalDo copts' (runBrickUi opts)

runBrickUi :: UIOpts -> Journal -> IO ()
runBrickUi uopts0@UIOpts{uoCliOpts=copts@CliOpts{inputopts_=_iopts,reportspec_=rspec@ReportSpec{_rsReportOpts=ropts}}} j =
  dlogUiTrace "========= runBrickUi" $ do
  let
    today = copts^.rsDay

    -- hledger-ui's query handling is currently in flux, mixing old and new approaches.
    -- Related: #1340, #1383, #1387. Some notes and terminology:

    -- The *startup query* is the Query generated at program startup, from
    -- command line options, arguments, and the current date. hledger CLI
    -- uses this.

    -- hledger-ui/hledger-web allow the query to be changed at will, creating
    -- a new *runtime query* each time.

    -- The startup query or part of it can be used as a *constraint query*,
    -- limiting all runtime queries. hledger-web does this with the startup
    -- report period, never showing transactions outside those dates.
    -- hledger-ui does not do this.

    -- A query is a combination of multiple subqueries/terms, which are
    -- generated from command line options and arguments, ui/web app runtime
    -- state, and/or the current date.

    -- Some subqueries are generated by parsing freeform user input, which
    -- can fail. We don't want hledger users to see such failures except:

    -- 1. at program startup, in which case the program exits
    -- 2. after entering a new freeform query in hledger-ui/web, in which case
    --    the change is rejected and the program keeps running

    -- So we should parse those kinds of subquery only at those times. Any
    -- subqueries which do not require parsing can be kept separate. And
    -- these can be combined to make the full query when needed, eg when
    -- hledger-ui screens are generating their data. (TODO)

    -- Some parts of the query are also kept separate for UI reasons.
    -- hledger-ui provides special UI for controlling depth (number keys), 
    -- the report period (shift arrow keys), realness/status filters (RUPC keys) etc.
    -- There is also a freeform text area for extra query terms (/ key).
    -- It's cleaner and less conflicting to keep the former out of the latter.

    uopts = uopts0{
      uoCliOpts=copts{
         reportspec_=rspec{
            _rsQuery=filteredQuery $ _rsQuery rspec,  -- query with depth/date parts removed
            _rsReportOpts=ropts{
               depth_ =queryDepth $ _rsQuery rspec,  -- query's depth part
               period_=periodfromoptsandargs,       -- query's date part
               no_elide_=True,  -- avoid squashing boring account names, for a more regular tree (unlike hledger)
               empty_=not $ empty_ ropts  -- show zero items by default, hide them with -E (unlike hledger)
               }
            }
         }
      }
      where
        datespanfromargs = queryDateSpan (date2_ ropts) $ _rsQuery rspec
        periodfromoptsandargs =
          dateSpanAsPeriod $ spansIntersect [periodAsDateSpan $ period_ ropts, datespanfromargs]
        filteredQuery q = simplifyQuery $ And [queryFromFlags ropts, filtered q]
          where filtered = filterQuery (\x -> not $ queryIsDepth x || queryIsDate x)

    -- select the starting screen, and parent screens you can step back to:
    -- menu > accounts by default, or menu > accounts > register with --register.
    (prevscrs, startscr) = case uoRegister uopts of
      Nothing   -> ([menuscr], acctsscr)
      Just apat -> ([menuscr, asSetSelectedAccount acct acctsscr], regscr)
        where
          regscr = 
            rsSetAccount acct False $
            rsNew uopts today j acct forceinclusive
              where
                forceinclusive = case getDepth ui of
                                  Just de -> accountNameLevel acct >= de
                                  Nothing -> False
          acct = fromMaybe (error' $ "--register "++apat++" did not match any account")  -- PARTIAL:
            . firstMatch $ journalAccountNamesDeclaredOrImplied j
            where
              firstMatch = case toRegexCI $ T.pack apat of
                  Right re -> find (regexMatchText re)
                  Left  _  -> const Nothing
      where
        menuscr = msNew
        acctsscr = asNew uopts today j Nothing

    ui = uiState uopts j prevscrs startscr
    app = brickApp (uoTheme uopts)

  -- print (length (show ui)) >> exitSuccess  -- show any debug output to this point & quit

  let 
    -- helper: make a Vty terminal controller with mouse support enabled
    makevty = do
      v <- mkVty mempty
      setMode (outputIface v) Mouse True
      return v

  if not (uoWatch uopts)
  then do
    vty <- makevty
    void $ customMain vty makevty Nothing app ui

  else do
    -- a channel for sending misc. events to the app
    eventChan <- newChan

    -- start a background thread reporting changes in the current date
    -- use async for proper child termination in GHCI
    let
      watchDate old = do
        threadDelay 1000000 -- 1 s
        new <- getCurrentDay
        when (new /= old) $ do
          let dc = DateChange old new
          -- dbg1IO "datechange" dc -- XXX don't uncomment until dbg*IO fixed to use traceIO, GHC may block/end thread
          -- traceIO $ show dc
          writeChan eventChan dc
        watchDate new

    withAsync
      -- run this small task asynchronously:
      (getCurrentDay >>= watchDate)
      -- until this main task terminates:
      $ \_async ->
      -- start one or more background threads reporting changes in the directories of our files
      -- XXX many quick successive saves causes the problems listed in BUGS
      -- with Debounce increased to 1s it easily gets stuck on an error or blank screen
      -- until you press g, but it becomes responsive again quickly.
      -- withManagerConf defaultConfig{confDebounce=Debounce 1} $ \mgr -> do
      -- with Debounce at the default 1ms it clears transient errors itself
      -- but gets tied up for ages
      withManager $ \mgr -> do
        dbg1IO "fsnotify using polling ?" $ isPollingManager mgr
        files <- mapM (canonicalizePath . fst) $ jfiles j
        let directories = nubSort $ map takeDirectory files
        dbg1IO "files" files
        dbg1IO "directories to watch" directories

        forM_ directories $ \d -> watchDir
          mgr
          d
          -- predicate: ignore changes not involving our files
          (\case
            Modified f _ False -> f `elem` files
            -- Added    f _ -> f `elem` files
            -- Removed  f _ -> f `elem` files
            -- we don't handle adding/removing journal files right now
            -- and there might be some of those events from tmp files
            -- clogging things up so let's ignore them
            _ -> False
            )
          -- action: send event to app
          (\fev -> do
            -- return $ dbglog "fsnotify" $ showFSNEvent fev -- not working
            dbg1IO "fsnotify" $ show fev
            writeChan eventChan FileChange
            )

        -- and start the app. Must be inside the withManager block. (XXX makevty too ?)
        vty <- makevty
        void $ customMain vty makevty (Just eventChan) app ui

brickApp :: Maybe String -> App UIState AppEvent Name
brickApp mtheme = App {
    appStartEvent   = return ()
  , appAttrMap      = const $ fromMaybe defaultTheme $ getTheme =<< mtheme
  , appChooseCursor = showFirstCursor
  , appHandleEvent  = uiHandle
  , appDraw         = uiDraw
  }

uiHandle :: BrickEvent Name AppEvent -> EventM Name UIState ()
uiHandle ev = do
  ui <- get
  case aScreen ui of
    MS _ -> msHandle ev
    AS _ -> asHandle ev
    BS _ -> bsHandle ev
    RS _ -> rsHandle ev
    TS _ -> tsHandle ev
    ES _ -> esHandle ev

uiDraw :: UIState -> [Widget Name]
uiDraw ui =
  case aScreen ui of
    MS _ -> msDraw ui
    AS _ -> asDraw ui
    BS _ -> bsDraw ui
    RS _ -> rsDraw ui
    TS _ -> tsDraw ui
    ES _ -> esDraw ui
