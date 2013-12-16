-- |
-- Copyright: 2013 (C) Amgen, Inc
--
-- Wrappers for low level R functions

{-# LANGUAGE ForeignFunctionInterface #-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

module Language.R
  ( r1
  , r2
  , parseFile
  , parseText
  , withProtected
  , symbol
  , install
  , string
  , strings
  , eval
  , evalEnv
  -- * R global constants
  -- $ghci-bug
  , pokeRVariables
  , peekRVariables
  , globalEnvPtr
  , baseEnvPtr
  , nilValuePtr
  , unboundValuePtr
  , missingArgPtr
  , rInteractive
  , rCStackLimitPtr
  , rInputHandlersPtr
  , MonadR(..)
  , throwR
  , throwRMessage
  -- * Helpers
  -- $helpers
  ) where


import Foreign.R (SEXP)
import qualified Foreign.R as R
import qualified Foreign.R.Parse as R
import qualified Foreign.R.Error as R
import qualified Foreign.R.Interface as R ( StackSize )

import Control.Applicative
import Control.Exception ( bracket, throwIO )
import Control.Monad ( (<=<), (>=>), when, unless )
import Control.Monad.IO.Class
import Data.ByteString as B
import Data.ByteString.Char8 as C8 ( pack, unpack )
import Data.Word
import Foreign
    ( alloca
    , peek
    , Ptr
    , poke
    , newStablePtr
    , deRefStablePtr
    , StablePtr
    )
import Foreign.C.String ( withCString, peekCString )
import Foreign.C.Types ( CInt(..) )
import System.IO.Unsafe ( unsafePerformIO )

-- $ghci-bug
-- The main reason to have all R constants referenced with a StablePtr
-- is that variables in shared libraries are linked incorrectly by GHCi with
-- loaded code.
--
-- The workaround is to grab all variables in the ghci session for the loaded
-- code to use them, that is currently done by the H.ghci script.
--
-- Upstream ticket: <https://ghc.haskell.org/trac/ghc/ticket/8549#ticket>

type RVariables =
    ( Ptr (SEXP R.Env)
    , Ptr (SEXP R.Env)
    , Ptr (SEXP R.Nil)
    , Ptr (SEXP R.Symbol)
    , Ptr (SEXP R.Symbol)
    , Ptr CInt
    , Ptr R.StackSize
    , Ptr (Ptr ())
    )

-- | Stores R variables in a static location. This has the variables addresses
-- accesible after GHCi reloadings.
pokeRVariables :: RVariables -> IO ()
pokeRVariables = poke rVariables <=< newStablePtr

-- | Retrieves R variables.
peekRVariables :: RVariables
peekRVariables = unsafePerformIO $ peek rVariables >>= deRefStablePtr

(  globalEnvPtr
 , baseEnvPtr
 , nilValuePtr
 , unboundValuePtr
 , missingArgPtr
 , rInteractive
 , rCStackLimitPtr
 , rInputHandlersPtr
 ) = peekRVariables

foreign import ccall "missing_r.h &" rVariables :: Ptr (StablePtr RVariables)

-- | Parse and then evaluate expression.
parseEval :: ByteString -> IO (SEXP a)
parseEval txt = useAsCString txt $ \ctxt ->
  withProtected (R.mkString ctxt) $ \rtxt ->
    alloca $ \status -> do
      nil <- peek nilValuePtr
      withProtected (R.parseVector rtxt 1 status nil) $ \ex -> do
        e <- fromIntegral <$> peek status
        unless (R.PARSE_OK == toEnum e) $
          throwRMessage $ "Parse error in: " ++ C8.unpack txt
        eval =<< R.indexExpr ex 0

-- $helpers
-- This section contains a bunch of functions that are used internally on
-- a low level and wraps are simple that are too cheap to run under high
-- level interface.

-- | Call 1-arity R function by name in a global environment.
--
-- This function is done mainly for testing purposes, and execution of R
-- code in case that we can't construct symbol by other methods.
r1 :: ByteString -> SEXP a -> SEXP b
r1 fn a =
    unsafePerformIO $
      useAsCString fn $ \cfn -> R.install cfn >>= \f ->
        withProtected (R.lang2 f a) eval

-- | Call 2-arity R function, function will be found in runtime, using
-- global environment. See 'r1' for additional comments.
r2 :: ByteString -> SEXP a -> SEXP b -> SEXP c
r2 fn a b =
    unsafePerformIO $
      useAsCString fn $ \cfn -> R.install cfn >>= \f ->
      withProtected (R.lang3 f a b) eval

-- | Perform an action with resource while protecting it from the garbage
-- collection.
withProtected :: IO (SEXP a)      -- Action to accure resource
              -> (SEXP a -> IO b) -- Action
              -> IO b
withProtected accure =
   bracket (accure >>= \x -> R.protect x >> return x)
           (const (R.unprotect 1))

-- | Parse file and perform some actions on parsed file.
--
-- This function uses continuation because this is an easy way to make
-- operations GC-safe.
--
-- This function is not safe to use inside GHCi.
parseFile :: FilePath -> (SEXP (R.Vector (SEXP R.Any)) -> IO a) -> IO a
parseFile fl f = do
    withCString fl $ \cfl ->
      withProtected (R.mkString cfl) $ \rfl ->
        withProtected (return $ r1 (C8.pack "parse") rfl) f

parseText :: String -> Bool -> IO (R.SEXP R.Expr)
parseText txt b = parseEval (C8.pack $ "parse(text="++show txt++",keep.source="++keep++")")
  where
    keep | b         = "TRUE"
         | otherwise = "FALSE"

install :: String -> IO (SEXP R.Symbol)
install str = withCString str R.install

symbol :: String -> IO (SEXP R.Symbol)
symbol str = withCString str $ \cstr -> R.install cstr

string :: String -> IO (SEXP (R.Vector Word8))
string str = withCString str R.mkChar

strings :: String -> IO (SEXP (R.String))
strings str = withCString str R.mkString

-- | Evaluate expression in given environment.
evalEnv :: SEXP a -> SEXP R.Env -> IO (SEXP b)
evalEnv x rho =
    alloca $ \p -> do
        v <- R.tryEvalSilent x rho p
        e <- peek p
        when (e /= 0) $ do
          throwR rho
        return v

-- | Evaluate expression in global environment.
eval :: SEXP a -> IO (SEXP b)
eval x = peek globalEnvPtr >>= evalEnv x

class (Applicative m, MonadIO m) => MonadR m where
  -- | Prepare unsafe action for execution
  io :: IO a -> m a
  io = liftIO

-- | Throw R exception.
throwR :: R.SEXP R.Env  -- Environment to search error.
       -> IO a
throwR x = getErrMsg x >>= throwIO . R.RError

-- | Throw R exception with specified message.
throwRMessage :: String -> IO a
throwRMessage = throwIO . R.RError

-- | Read last error message.
getErrMsg :: R.SEXP R.Env -> IO String
getErrMsg e = do
  f <- withCString "geterrmessage" (R.install >=> R.lang1)
  peekCString =<< R.char =<< peek =<< R.string =<< R.eval f e
