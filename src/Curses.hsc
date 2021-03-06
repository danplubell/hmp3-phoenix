--
-- Copyright (c) 2002-2004 John Meacham (john at repetae dot net)
-- Copyright (c) 2004-2008 Don Stewart - http://www.cse.unsw.edu.au/~dons
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
-- OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- 

--
-- | Binding to the [wn]curses library. From the ncurses man page:
--
-- >      The curses library routines give the user a terminal-inde-
-- >      pendent method of updating character screens with  reason-
-- >      able  optimization.
-- 
-- Sections of the quoted documentation are from the OpenBSD man pages,
-- which are distributed under a BSD license.
--
-- A useful reference is: 
--        /Writing Programs with NCURSES/, by Eric S. Raymond and Zeyd
--        M. Ben-Halim, <http://dickey.his.com/ncurses/>
--
-- attrs dont work with Irix curses.h. This should be fixed.
--

#include "utils.h"

module Curses (

    initCurses,     -- :: IO () -> IO ()
    resetParams,    -- :: IO ()

    stdScr,         -- :: Window
    endWin,         -- :: IO ()

    keypad,         -- :: Window -> Bool -> IO ()
    scrSize,        -- :: IO (Int, Int)
    refresh,        -- :: IO ()
    getCh,          -- :: IO Char

    -- * Line drawing
    waddnstr,       -- :: Window -> CString -> CInt -> IO CInt
    bkgrndSet,      -- :: Attr -> Pair -> IO ()
    clrToEol,       -- :: IO ()
    wMove,          -- :: Window -> Int -> Int -> IO ()

    -- * Key codes
    keyBackspace, keyUp, keyDown, keyNPage, keyHome, keyPPage, keyEnd,
    keyLeft, keyRight,
#ifdef KEY_RESIZE
    keyResize,
#endif

    -- * Cursor
    CursorVisibility(..),
    cursSet,        -- :: CInt -> IO CInt
    getYX,          -- :: Window -> IO (Int, Int)

    -- * Colours
    Pair(..), Color,
    initPair,           -- :: Pair -> Color -> Color -> IO ()
    color,              -- :: String -> Maybe Color
    hasColors,          -- :: IO Bool

    -- * Attributes
    Attr,
    attr0, setBold, setReverse,
    attrSet,
    attrPlus,           -- :: Attr -> Attr -> Attr

    -- * error handling
    throwIfErr_,    -- :: Num a => String -> IO a -> IO ()

  ) where 

#if HAVE_SIGNAL_H
# include <signal.h>
#endif

import qualified Data.ByteString.Char8 as P

import Prelude hiding       (pi)
import Data.Char            (ord, chr)

import Control.Monad        (liftM, when, void)
import Control.Concurrent   (yield, threadWaitRead)

import Foreign.C.Types      (CInt(..), CShort(..))
import Foreign.C.String     (CString)
import Foreign hiding (void)
import System.IO.Unsafe 
#ifdef SIGWINCH
import System.Posix.Signals (installHandler, Signal, Handler(Catch))
#endif

--
-- If we have the SIGWINCH signal, we use that, with a custom handler,
-- to determine when to resize the screen. Otherwise, we use a similar
-- handler that looks for KEY_RESIZE in the input stream -- the result
-- is a less responsive update, however.
--

------------------------------------------------------------------------
--
-- | Start it all up
--
initCurses :: IO () -> IO ()
initCurses _ = do
    void $ initScr
    b <- hasColors
    when b $ startColor >> useDefaultColors
    resetParams
#ifdef SIGWINCH
    -- does this still work?
    installHandler cursesSigWinch (Catch fn) Nothing >> return ()
#endif

-- | A bunch of settings we need
--
resetParams :: IO ()
resetParams = do
    cBreak True
    echo False          -- don't echo to the screen
    nl True             -- always translate enter to \n
    void $ leaveOk True        -- not ok to leave cursor wherever it is
    meta stdScr True    -- ask for 8 bit chars, so we can get Meta
    keypad stdScr True  -- enable the keypad, so things like ^L (refresh) work
    noDelay stdScr False  -- blocking getCh, no #ERR
    return ()

-- not needed, if keypad is True:
--  defineKey (#const KEY_UP) "\x1b[1;2A"
--  defineKey (#const KEY_DOWN) "\x1b[1;2B"
--  defineKey (#const KEY_SLEFT) "\x1b[1;2D"
--  defineKey (#const KEY_SRIGHT) "\x1b[1;2C"

------------------------------------------------------------------------

fi :: (Integral a, Num b) => a -> b
fi = fromIntegral
{-# INLINE fi #-}

------------------------------------------------------------------------
-- 
-- Error handling, packed to save on all those strings
--

-- | Like throwIf, but for packed error messages
throwPackedIf :: (a -> Bool) -> P.ByteString -> (IO a) -> (IO a)
throwPackedIf p msg action = do
    v <- action
    if p v then (fail . P.unpack $ msg) else return v
{-# INLINE throwPackedIf #-}

-- | Arbitrary test 
throwIfErr :: (Num a,Eq a) => P.ByteString -> IO a -> IO a
throwIfErr = throwPackedIf (== (#const ERR))
{-# INLINE throwIfErr #-}

-- | Discard result
throwIfErr_ :: (Eq a, Num a) => P.ByteString -> IO a -> IO ()
throwIfErr_ a b = void $ throwIfErr a b
{-# INLINE throwIfErr_ #-}

-- | packed throwIfNull
throwPackedIfNull :: P.ByteString -> IO (Ptr a) -> IO (Ptr a)
throwPackedIfNull = throwPackedIf (== nullPtr)
{-# INLINE throwPackedIfNull #-}

------------------------------------------------------------------------

type WindowTag = ()
type Window = Ptr WindowTag

--
-- | The standard screen
--
stdScr :: Window
stdScr = unsafePerformIO (peek stdscr)

foreign import ccall "static &stdscr" 
    stdscr :: Ptr Window

--
-- | initscr is normally the first curses routine to call when
-- initializing a program. curs_initscr(3):
--
-- > To initialize the routines, the routine initscr or newterm
-- > must be called before any of the other routines that  deal
-- > with  windows  and  screens  are used. 
--
-- > The initscr code determines the terminal type and initial-
-- > izes all curses data structures.  initscr also causes  the
-- > first  call  to  refresh  to  clear the screen.  If errors
-- > occur, initscr writes  an  appropriate  error  message  to
-- > standard error and exits; otherwise, a pointer is returned
-- > to stdscr.
--
initScr :: IO Window
initScr = throwPackedIfNull (P.pack "initscr") c_initscr

foreign import ccall unsafe "initscr" 
    c_initscr :: IO Window

--
-- |> The cbreak routine
-- > disables line buffering and erase/kill  character-process-
-- > ing  (interrupt  and  flow  control  characters  are unaf-
-- > fected), making characters typed by the  user  immediately
-- > available  to  the  program.  The nocbreak routine returns
-- > the terminal to normal (cooked) mode.
--
cBreak :: Bool -> IO ()
cBreak True  = throwIfErr_ (P.pack "cbreak")   cbreak
cBreak False = throwIfErr_ (P.pack "nocbreak") nocbreak

foreign import ccall unsafe "cbreak"     cbreak :: IO CInt
foreign import ccall unsafe "nocbreak" nocbreak :: IO CInt

--
-- |> The  echo  and  noecho routines control whether characters
-- > typed by the user are echoed by getch as they  are  typed.
-- > Echoing  by  the  tty  driver is always disabled, but ini-
-- > tially getch is in echo  mode,  so  characters  typed  are
-- > echoed.  Authors of most interactive programs prefer to do
-- > their own echoing in a controlled area of the  screen,  or
-- > not  to  echo  at  all, so they disable echoing by calling
-- > noecho.  [See curs_getch(3) for a discussion of how  these
-- > routines interact with cbreak and nocbreak.]
--
echo :: Bool -> IO ()
echo False = throwIfErr_ (P.pack "noecho") noecho
echo True  = throwIfErr_ (P.pack "echo")   echo_c

foreign import ccall unsafe "noecho" noecho :: IO CInt
foreign import ccall unsafe "echo"   echo_c :: IO CInt

--
-- |> The  nl  and  nonl routines control whether the underlying
-- > display device translates the return key into  newline  on
-- > input,  and  whether it translates newline into return and
-- > line-feed on output (in either case, the call  addch('\n')
-- > does the equivalent of return and line feed on the virtual
-- > screen).  Initially, these translations do occur.  If  you
-- > disable  them using nonl, curses will be able to make bet-
-- > ter use of the line-feed capability, resulting  in  faster
-- > cursor  motion.   Also, curses will then be able to detect
-- > the return key.
-- > 
nl :: Bool -> IO ()
nl True  = throwIfErr_ (P.pack "nl") nl_c
nl False = throwIfErr_ (P.pack "nonl") nonl

foreign import ccall unsafe "nl" nl_c :: IO CInt
foreign import ccall unsafe "nonl" nonl :: IO CInt

--
-- | Enable the keypad of the user's terminal.
--
keypad :: Window -> Bool -> IO ()
keypad win bf = throwIfErr_ (P.pack "keypad") $ 
    keypad_c win (if bf then 1 else 0)

foreign import ccall unsafe "keypad" 
    keypad_c :: Window -> (#type bool) -> IO CInt

-- |> The nodelay option causes getch to be a non-blocking call.
-- > If  no input is ready, getch returns ERR.  If disabled (bf
-- > is FALSE), getch waits until a key is pressed.
--
noDelay :: Window -> Bool -> IO ()
noDelay win bf = throwIfErr_ (P.pack "nodelay") $ 
    nodelay win (if bf then 1 else 0)

foreign import ccall unsafe nodelay 
    :: Window -> (#type bool) -> IO CInt

--
-- |> Normally, the hardware cursor is left at the  location  of
-- > the  window  cursor  being  refreshed.  The leaveok option
-- > allows the cursor to be left wherever the  update  happens
-- > to leave it.  It is useful for applications where the cur-
-- > sor is not used, since it  reduces  the  need  for  cursor
-- > motions.   If  possible, the cursor is made invisible when
-- > this option is enabled.
--
leaveOk  :: Bool -> IO CInt
leaveOk bf = leaveok_c stdScr (if bf then 1 else 0)

foreign import ccall unsafe "leaveok" 
    leaveok_c :: Window -> (#type bool) -> IO CInt

------------------------------------------------------------------------

-- | The use_default_colors() and assume_default_colors() func-
--   tions are extensions to the curses library.  They are used
--   with terminals that support ISO 6429 color, or equivalent.
--
--  use_default_colors() tells the  curses library  to  assign terminal
--  default foreground/background colors to color number  -1.
--
#if defined(HAVE_USE_DEFAULT_COLORS)
foreign import ccall unsafe "use_default_colors" 
    useDefaultColors :: IO ()
#else
useDefaultColors :: IO ()
useDefaultColors = return ()
#endif

------------------------------------------------------------------------

--
-- |> The program must call endwin for each terminal being used before
-- > exiting from curses.
--
endWin :: IO ()
endWin = throwIfErr_ (P.pack "endwin") endwin

foreign import ccall unsafe "endwin" 
    endwin :: IO CInt

------------------------------------------------------------------------

--
-- | get the dimensions of the screen
--
scrSize :: IO (Int, Int)
scrSize = do
    lnes <- peek linesPtr
    cols <- peek colsPtr
    return (fi lnes, fi cols)

foreign import ccall "&LINES" linesPtr :: Ptr CInt
foreign import ccall "&COLS"  colsPtr  :: Ptr CInt

--
-- | refresh curses windows and lines. curs_refresh(3)
--
refresh :: IO ()
refresh = throwIfErr_ (P.pack "refresh") refresh_c

foreign import ccall unsafe "refresh" 
    refresh_c :: IO CInt

------------------------------------------------------------------------

hasColors :: IO Bool
hasColors = liftM (/= 0) has_colors

foreign import ccall unsafe "has_colors" 
    has_colors :: IO (#type bool)

--
-- | Initialise the color settings, also sets the screen to the
-- default colors (white on black)
--
startColor :: IO ()
startColor = throwIfErr_ (P.pack "start_color") start_color

foreign import ccall unsafe start_color :: IO CInt

newtype Pair  = Pair Int
newtype Color = Color Int

color :: String -> Maybe Color
#if defined(HAVE_USE_DEFAULT_COLORS)
color "default"  = Just $ Color (-1)
#endif
color "black"    = Just $ Color (#const COLOR_BLACK)
color "red"      = Just $ Color (#const COLOR_RED)
color "green"    = Just $ Color (#const COLOR_GREEN)
color "yellow"   = Just $ Color (#const COLOR_YELLOW)
color "blue"     = Just $ Color (#const COLOR_BLUE)
color "magenta"  = Just $ Color (#const COLOR_MAGENTA)
color "cyan"     = Just $ Color (#const COLOR_CYAN)
color "white"    = Just $ Color (#const COLOR_WHITE)
color _          = Just $ Color (#const COLOR_BLACK)    -- NB

--
-- |> curses support color attributes  on  terminals  with  that
-- > capability.   To  use  these  routines start_color must be
-- > called, usually right after initscr.   Colors  are  always
-- > used  in pairs (referred to as color-pairs).  A color-pair
-- > consists of a foreground  color  (for  characters)  and  a
-- > background color (for the blank field on which the charac-
-- > ters are displayed).  A programmer  initializes  a  color-
-- > pair  with  the routine init_pair.  After it has been ini-
-- > tialized, COLOR_PAIR(n), a macro  defined  in  <curses.h>,
-- > can be used as a new video attribute.
--
-- > If  a  terminal  is capable of redefining colors, the pro-
-- > grammer can use the routine init_color to change the defi-
-- > nition   of   a   color.
--
-- > The init_pair routine changes the definition of  a  color-
-- > pair.   It takes three arguments: the number of the color-
-- > pair to be changed, the foreground color number,  and  the
-- > background color number.  For portable applications:
--
-- > -  The value of the first argument must be between 1 and
-- >    COLOR_PAIRS-1.
--
-- > -  The value of the second and third arguments  must  be
-- >    between  0  and  COLORS (the 0 color pair is wired to
-- >    white on black and cannot be changed).
--
--
initPair :: Pair -> Color -> Color -> IO ()
initPair (Pair p) (Color f) (Color b) =
    throwIfErr_ (P.pack "init_pair") $
        init_pair (fi p) (fi f) (fi b)

foreign import ccall unsafe 
    init_pair :: CShort -> CShort -> CShort -> IO CInt

-- ---------------------------------------------------------------------
-- Attributes. Keep this as simple as possible for maximum portability

foreign import ccall unsafe "attrset"
    c_attrset :: CInt -> IO CInt

attrSet :: Attr -> Pair -> IO ()
attrSet (Attr attr) (Pair p) = do
    throwIfErr_ (P.pack "attrset")   $ c_attrset (attr .|. fi (colorPair p))

------------------------------------------------------------------------

newtype Attr = Attr CInt

attr0   :: Attr
attr0   = Attr (#const A_NORMAL)

setBold :: Attr -> Bool -> Attr
setBold = setAttr (Attr #const A_BOLD)

setReverse :: Attr -> Bool -> Attr
setReverse = setAttr (Attr #const A_REVERSE)

-- | bitwise combination of attributes
setAttr :: Attr -> Attr -> Bool -> Attr
setAttr (Attr b) (Attr a) False = Attr (a .&. complement b)
setAttr (Attr b) (Attr a) True  = Attr (a .|.            b)

attrPlus :: Attr -> Attr -> Attr
attrPlus (Attr a) (Attr b) = Attr (a .|. b)

------------------------------------------------------------------------

#let translate_attr attr =                              \
    "(if a .&. %lu /= 0 then %lu else 0) .|.",          \
    (unsigned long) A_##attr, (unsigned long) A_##attr

bkgrndSet :: Attr -> Pair -> IO ()
bkgrndSet (Attr a) (Pair p) = bkgdset $
    fi (ord ' ') .|.
    #translate_attr ALTCHARSET
    #translate_attr BLINK
    #translate_attr BOLD
    #translate_attr DIM
    #translate_attr INVIS
    #translate_attr PROTECT
    #translate_attr REVERSE
    #translate_attr STANDOUT
    #translate_attr UNDERLINE
    colorPair p

foreign import ccall unsafe "get_color_pair" 
    colorPair :: Int -> (#type chtype)

foreign import ccall unsafe bkgdset :: (#type chtype) -> IO ()

-- ----------------------------------------------------------------------

foreign import ccall safe
    waddnstr :: Window -> CString -> CInt -> IO CInt

clrToEol :: IO ()
clrToEol = throwIfErr_ (P.pack "clrtoeol") c_clrtoeol

foreign import ccall unsafe "clrtoeol" c_clrtoeol :: IO CInt

--
-- | >    move the cursor associated with the window
--   >    to line y and column x.  This routine does  not  move  the
--   >    physical  cursor  of the terminal until refresh is called.
--   >    The position specified is relative to the upper  left-hand
--   >    corner of the window, which is (0,0).
--
wMove :: Window -> Int -> Int -> IO ()
wMove w y x = throwIfErr_ (P.pack "wmove") $ wmove w (fi y) (fi x)

foreign import ccall unsafe  
    wmove :: Window -> CInt -> CInt -> IO CInt

-- ---------------------------------------------------------------------
-- Cursor routines

data CursorVisibility = CursorInvisible | CursorVisible | CursorVeryVisible

--
-- | Set the cursor state
--
-- >       The curs_set routine sets  the  cursor  state  is  set  to
-- >       invisible, normal, or very visible for visibility equal to
-- >       0, 1, or 2 respectively.  If  the  terminal  supports  the
-- >       visibility   requested,   the  previous  cursor  state  is
-- >       returned; otherwise, ERR is returned.
--
cursSet :: CInt -> IO CInt
cursSet 0 = leaveOk True  >> curs_set 0
cursSet n = leaveOk False >> curs_set n 

foreign import ccall unsafe "curs_set" 
    curs_set :: CInt -> IO CInt

-- 
-- | Get the current cursor coordinates
--
getYX :: Window -> IO (Int, Int)
getYX w =
    alloca $ \py ->                 -- allocate two ints on the stack
        alloca $ \px -> do
            nomacro_getyx w py px   -- writes current cursor coords
            y <- peek py
            x <- peek px
            return (fi y, fi x)

--
-- | Get the current cursor coords, written into the two argument ints.
--
-- >    The getyx macro places the current cursor position of the given
-- >    window in the two integer variables y and x.
--
--      void getyx(WINDOW *win, int y, int x);
--
foreign import ccall unsafe "nomacro_getyx" 
        nomacro_getyx :: Window -> Ptr CInt -> Ptr CInt -> IO ()

--
-- | >      The getch, wgetch, mvgetch and mvwgetch, routines read a
--   >      character  from the window.
--
foreign import ccall safe getch :: IO CInt

------------------------------------------------------------------------
--
-- | Map curses keys to real chars. The lexer will like this.
--
decodeKey :: CInt -> Char
decodeKey = chr . fi
{-# INLINE decodeKey #-}

--
-- | Some constants for easy symbolic manipulation.
-- NB we don't map keys to an abstract type anymore, as we can't use
-- Alex lexers then.
--
keyDown :: Char
keyDown         = chr (#const KEY_DOWN)
keyUp :: Char
keyUp           = chr (#const KEY_UP)
keyLeft :: Char
keyLeft         = chr (#const KEY_LEFT)
keyRight :: Char
keyRight        = chr (#const KEY_RIGHT)

keyHome :: Char
keyHome         = chr (#const KEY_HOME)
keyBackspace :: Char
keyBackspace    = chr (#const KEY_BACKSPACE)

keyNPage :: Char
keyNPage        = chr (#const KEY_NPAGE)
keyPPage :: Char
keyPPage        = chr (#const KEY_PPAGE)
keyEnd :: Char
keyEnd          = chr (#const KEY_END)

#ifdef KEY_RESIZE
-- ncurses sends this
keyResize :: Char
keyResize       = chr (#const KEY_RESIZE)
#endif

-- ---------------------------------------------------------------------
-- try to set the upper bits

meta :: Window -> Bool -> IO ()
meta win bf = throwIfErr_ (P.pack "meta") $
    c_meta win (if bf then 1 else 0)

foreign import ccall unsafe "meta" 
    c_meta :: Window -> CInt -> IO CInt

------------------------------------------------------------------------
--
-- | read a character from the window
--
-- When 'ESC' followed by another key is pressed before the ESC timeout,
-- that second character is not returned until a third character is
-- pressed. wtimeout, nodelay and timeout don't appear to change this
-- behaviour.
-- 
-- On emacs, we really would want Alt to be our meta key, I think.
--
-- Be warned, getCh will block the whole process without noDelay
--
getCh :: IO Char
getCh = do
    threadWaitRead 0
    v <- getch
    case v of
        (#const ERR) -> yield >> getCh
        x            -> return $ decodeKey x

------------------------------------------------------------------------

#ifdef SIGWINCH
cursesSigWinch :: Signal
cursesSigWinch = #const SIGWINCH
#endif

