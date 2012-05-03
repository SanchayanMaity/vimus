{-# LANGUAGE GeneralizedNewtypeDeriving, ExistentialQuantification #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Vimus (
  Vimus
, runVimus

-- * search
, search
, filter_
, searchNext
, searchPrev

-- * macros
, clearMacros
, addMacro
, removeMacro
, getMacros

, TabName (..)
, CloseMode (..)
, Tab (..)
, Event (..)
, sendEvent
, sendEventCurrent

, Widget (..)
, AnyWidget (..)
, SearchOrder (..)

, printMessage
, printError

, LogMessage
, logMessages

, copy
, copyRegister

-- * tabs
, previousTab
, nextTab
, selectTab
, addTab
, closeTab

, getCurrentWidget
, withCurrentSong
, withCurrentItem

, setMainWindow
, renderMainWindow
, renderToMainWindow
, renderTabBar

, getLibraryPath
, setLibraryPath
) where

import           Prelude hiding (mapM, mapM_)
import           Data.Functor
import           Data.Maybe (fromMaybe)
import           Data.Traversable (mapM)
import           Data.Foldable (forM_, mapM_)
import           Control.Monad (unless)

import           Control.Monad.State.Strict (liftIO, gets, get, put, modify, evalStateT, StateT, MonadState)
import           Control.Monad.Trans (MonadIO)

import           Data.Default

import           System.Time (getClockTime, toCalendarTime, formatCalendarTime)
import           System.Locale (defaultTimeLocale)

import           Network.MPD.Core
import           Network.MPD as MPD (LsResult)
import qualified Network.MPD as MPD hiding (withMPD)

import           UI.Curses hiding (mvwchgat)

import           ListWidget (Renderable (..))

import qualified Macro
import           Macro (Macros)

import           Content
import           Type

import           Tab (Tab(..), TabName(..), CloseMode(..))
import qualified Tab
import           WindowLayout (WindowColor(..), mvwchgat)

import           Control.Monad.Error.Class
import           Util (expandHome)

class Widget a where
  render      :: a -> Window -> IO ()
  event       :: a -> Event -> Vimus (Maybe a)
  currentItem :: a -> Maybe Content
  searchItem  :: a -> SearchOrder -> String -> a
  filterItem  :: a -> String -> a

data AnyWidget = forall w. Widget w => AnyWidget w

instance Widget AnyWidget where
  render (AnyWidget w)          = render w
  event (AnyWidget w) e         = fmap AnyWidget <$> event w e
  currentItem (AnyWidget w)     = currentItem w
  searchItem (AnyWidget w) o  t = AnyWidget (searchItem w o t)
  filterItem (AnyWidget w) t    = AnyWidget (filterItem w t)

data SearchOrder = Forward | Backward

-- | Events
data Event =
    EvCurrentSongChanged (Maybe MPD.Song)
  | EvPlaylistChanged [MPD.Song]
  | EvLibraryChanged [LsResult]
  | EvResize WindowSize
  | EvMoveUp
  | EvMoveDown
  | EvMoveIn
  | EvMoveOut
  | EvMoveFirst
  | EvMoveLast
  | EvScrollUp
  | EvScrollDown
  | EvScrollPageUp
  | EvScrollPageDown
  | EvRemove
  | EvPaste
  | EvPastePrevious
  | EvLogMessage      -- ^ emitted when a message is added to the log

handleEvent :: Event -> AnyWidget -> Vimus AnyWidget
handleEvent ev widget = fromMaybe widget `fmap` event widget ev

-- | Send an event to all widgets.
sendEvent :: Event -> Vimus ()
sendEvent = modifyAllWidgets . handleEvent

-- | Send an event to current widget.
sendEventCurrent :: Event -> Vimus ()
sendEventCurrent ev = getCurrentWidget >>= (`event` ev) >>= mapM_ setCurrentWidget

-- | Search in current widget for given string.
search :: String -> Vimus ()
search term = do
  modify $ \state -> state { getLastSearchTerm = term }
  search_ Forward term

-- | Filter content of current widget.
filter_ :: String -> Vimus ()
filter_ term = do
  tab <- gets (Tab.current . tabView)

  let closeMode = max Closeable (tabCloseMode tab)
      searchResult = filterItem (tabContent tab) term

  case tabName tab of
    SearchResult -> setCurrentWidget searchResult
    _            -> addTab SearchResult searchResult closeMode

-- | Go to next search hit.
searchNext :: Vimus ()
searchNext = do
  state <- get
  search_ Forward $ getLastSearchTerm state

-- | Got to previous search hit.
searchPrev :: Vimus ()
searchPrev = do
  state <- get
  search_ Backward $ getLastSearchTerm state

search_ :: SearchOrder -> String -> Vimus ()
search_ order term = do
  widget <- getCurrentWidget
  setCurrentWidget (searchItem widget order term)

-- * log messages
newtype LogMessage = LogMessage String

instance Searchable LogMessage where
  searchTags (LogMessage m) = return m

instance Renderable LogMessage where
  renderItem (LogMessage m) = m


--- * the vimus monad
type Tabs = Tab.Tabs AnyWidget

data ProgramState = ProgramState {
  tabView            :: Tabs
, mainWindow         :: Window
, statusLine         :: Window
, tabWindow          :: Window
, getLastSearchTerm  :: String
, programStateMacros :: Macros
, libraryPath        :: Maybe String
, logMessages        :: [LogMessage]
, copyRegister       :: Maybe MPD.Path  -- ^ copy/paste register
}

-- | Put given path into copy/paste register.
copy :: MPD.Path -> Vimus ()
copy p = modify $ \st -> st {copyRegister = Just p}

newtype Vimus a = Vimus {unVimus :: (StateT ProgramState MPD a)}
  deriving (Functor, Monad, MonadIO, MonadState ProgramState, MonadError MPDError, MonadMPD)

instance (Default a) => Default (Vimus a) where
  def = return def


runVimus :: Tabs -> Window -> Window -> Window -> Vimus a -> MPD a
runVimus tabs mw statusWindow tw action = evalStateT (unVimus action_) st
  where
    action_ = sendResizeEvent >> action

    st = ProgramState {
        tabView            = tabs
      , mainWindow         = mw
      , statusLine         = statusWindow
      , tabWindow          = tw
      , getLastSearchTerm  = def
      , programStateMacros = def
      , libraryPath        = def
      , logMessages        = def
      , copyRegister       = def
      }

-- | Free current main window and set a new one.
--
-- This is necessary when the terminal is resized.  A resize event is
-- propagated to all widgets, and the screen is updated.
setMainWindow :: Window -> Vimus ()
setMainWindow window = do
  gets mainWindow >>= liftIO . delwin
  modify $ \st -> st {mainWindow = window}
  sendResizeEvent
  renderMainWindow

-- | Propagate size to all widgets.
sendResizeEvent :: Vimus ()
sendResizeEvent = getMainWindowSize >>= sendEvent . EvResize

-- | Get size of main window.
getMainWindowSize :: Vimus WindowSize
getMainWindowSize = gets mainWindow >>= liftIO . fmap (uncurry WindowSize) . getmaxyx


-- * macros

clearMacros :: Vimus ()
clearMacros = putMacros def

-- | Define a macro.
addMacro :: String -- ^ macro
         -> String -- ^ expansion
         -> Vimus ()
addMacro m c = gets programStateMacros >>= \ms -> putMacros (Macro.addMacro m c ms)

removeMacro :: String -> Vimus ()
removeMacro m = do
  macros <- gets programStateMacros
  either printError putMacros (Macro.removeMacro m macros)

getMacros :: Vimus Macros
getMacros = gets programStateMacros

-- a helper
putMacros :: Macros -> Vimus ()
putMacros ms = modify $ \st -> st {programStateMacros = ms}


-- | Print an error message.
printError :: String -> Vimus ()
printError message = do
  t <- formatCalendarTime defaultTimeLocale "%H:%M:%S - " <$> liftIO (getClockTime >>= toCalendarTime)
  modify $ \st -> st {logMessages = LogMessage (t ++ message) : logMessages st}
  window <- gets statusLine
  liftIO $ do
    werase window
    mvwaddstr window 0 0 message
    mvwchgat window 0 0 (-1) [] ErrorColor
    wrefresh window
    return ()
  sendEvent EvLogMessage

-- | Print a message.
printMessage :: String -> Vimus ()
printMessage message = do
  window <- gets statusLine
  liftIO $ do
    werase window
    mvwaddstr window 0 0 message
    wrefresh window
    return ()


addTab :: TabName -> AnyWidget -> CloseMode -> Vimus ()
addTab name widget mode = do
  modify (\st -> st {tabView = Tab.insert tab (tabView st)})
  renderTabBar
  where
    tab = Tab name widget mode

-- | Close current tab if possible, return True on success.
closeTab :: Vimus Bool
closeTab = do
  st <- get
  case Tab.close (tabView st) of
    Just tabs -> do
      put st {tabView = tabs}
      renderTabBar
      return True
    Nothing -> return False

-- | Get path to music library.
getLibraryPath :: Vimus (Maybe FilePath)
getLibraryPath = gets libraryPath

-- | Set path to music library.
--
-- This is need, if you want to use %-expansion in commands.
setLibraryPath :: FilePath -> Vimus ()
setLibraryPath path = liftIO (expandHome path) >>= either printError set
  where
    set p = modify (\state -> state {libraryPath = Just p})

modifyTabs :: (Tabs -> Tabs) -> Vimus ()
modifyTabs f = modify (\state -> state { tabView = f $ tabView state })

-- | Set focus to next tab with given name.
selectTab :: TabName -> Vimus ()
selectTab name = do
  modifyTabs $ Tab.select ((== name) . tabName)
  renderTabBar

-- | Set focus to next tab.
nextTab :: Vimus ()
nextTab = do
  modifyTabs Tab.next
  renderTabBar

-- | Set focus to previous tab.
previousTab :: Vimus ()
previousTab = do
  modifyTabs Tab.previous
  renderTabBar

-- | Run given action with currently selected song, if any
withCurrentSong :: Default a => (MPD.Song -> Vimus a) -> Vimus a
withCurrentSong action = do
  widget <- getCurrentWidget
  case currentItem widget of
    Just (Song song) -> action song
    _                -> def

-- | Run given action with currently selected item, if any
withCurrentItem :: Default a => (Content -> Vimus a) -> Vimus a
withCurrentItem action = getCurrentWidget >>= maybe def action . currentItem

-- | Perform an action on all widgets
modifyAllWidgets :: (AnyWidget -> Vimus AnyWidget) -> Vimus ()
modifyAllWidgets action = do
  tabs <- gets tabView >>= mapM action
  modify $ \st -> st {tabView = tabs}

getCurrentWidget :: Vimus AnyWidget
getCurrentWidget = gets (tabContent . Tab.current . tabView)

setCurrentWidget :: AnyWidget -> Vimus ()
setCurrentWidget w = modify (\st -> st {tabView = Tab.modify (w <$) (tabView st)})

-- | Render currently selected widget to main window.
renderMainWindow :: Vimus ()
renderMainWindow = getCurrentWidget >>= renderToMainWindow

-- | Render given widget to main window.
renderToMainWindow :: AnyWidget -> Vimus ()
renderToMainWindow l = do
  window <- gets mainWindow
  liftIO $ do
    werase window
    render l window
    wrefresh window
    return ()

-- |
-- Render the tab bar.
--
-- Needs to be called when ever the current tab changes.
renderTabBar :: Vimus ()
renderTabBar = do

  window <- gets tabWindow
  (pre, c, suf) <- Tab.preCurSuf <$> gets tabView

  let renderTab t = waddstr window $ " " ++ show (tabName t) ++ " "

  liftIO $ do
    werase window

    forM_ pre $ \tab -> do
      waddstr window "|"
      renderTab tab

    -- do not draw current tab if it is AutoClose
    unless (Tab.isAutoClose c) $ do
      waddstr window "|"
      wattr_on window [Bold]
      renderTab c
      wattr_off window [Bold]
      return ()

    waddstr window "|"

    forM_ suf $ \tab -> do
      renderTab tab
      waddstr window "|"

    wrefresh window
  return ()
