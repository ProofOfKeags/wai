{-# LANGUAGE CPP #-}
-- | In a multithreaded environment, running actions on a regularly scheduled
-- background thread can dramatically improve performance.
-- For example, web servers need to return the current time with each HTTP response.
-- For a high-volume server, it's much faster for a dedicated thread to run every
-- second, and write the current time to a shared 'IORef', than it is for each
-- request to make its own call to 'getCurrentTime'.
--
-- But for a low-volume server, whose request frequency is less than once per
-- second, that approach will result in /more/ calls to 'getCurrentTime' than
-- necessary, and worse, kills idle GC.
--
-- This library solves that problem by allowing you to define actions which will
-- either be performed by a dedicated thread, or, in times of low volume, will
-- be executed by the calling thread.
--
-- Example usage:
--
-- @
-- import "Data.Time"
-- import "Control.AutoUpdate"
--
-- getTime <- 'mkAutoUpdate' 'defaultUpdateSettings'
--              { 'updateAction' = 'Data.Time.Clock.getCurrentTime'
--              , 'updateFreq' = 1000000 -- The default frequency, once per second
--              }
-- currentTime <- getTime
-- @
--
-- For more examples, <http://www.yesodweb.com/blog/2014/08/announcing-auto-update see the blog post introducing this library>.
module Control.AutoUpdate (
      -- * Type
      UpdateSettings
    , defaultUpdateSettings
      -- * Accessors
    , updateAction
    , updateFreq
    , updateSpawnThreshold
      -- * Creation
    , mkAutoUpdate
    , mkAutoUpdateWithModify
    ) where

#if __GLASGOW_HASKELL__ < 709
import           Control.Applicative     ((<*>))
#endif
import           Control.Concurrent      (forkIO, threadDelay)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar,
                                          takeMVar, tryPutMVar)
import           Control.Exception       (SomeException, catch, mask_, throw,
                                          try)
import           Control.Monad           (void)
import           Data.IORef              (newIORef, readIORef, writeIORef)

-- | Default value for creating an 'UpdateSettings'.
--
-- @since 0.1.0
defaultUpdateSettings :: UpdateSettings ()
defaultUpdateSettings = UpdateSettings
    { updateFreq = 1000000
    , updateSpawnThreshold = 3
    , updateAction = return ()
    }

-- | Settings to control how values are updated.
--
-- This should be constructed using 'defaultUpdateSettings' and record
-- update syntax, e.g.:
--
-- @
-- let settings = 'defaultUpdateSettings' { 'updateAction' = 'Data.Time.Clock.getCurrentTime' }
-- @
--
-- @since 0.1.0
data UpdateSettings a = UpdateSettings
    { updateFreq           :: Int
    -- ^ Microseconds between update calls. Same considerations as
    -- 'threadDelay' apply.
    --
    -- Default: 1 second (1000000)
    --
    -- @since 0.1.0
    , updateSpawnThreshold :: Int
    -- ^ NOTE: This value no longer has any effect, since worker threads are
    -- dedicated instead of spawned on demand.
    --
    -- Previously, this determined how many times the data must be requested
    -- before we decide to spawn a dedicated thread.
    --
    -- Default: 3
    --
    -- @since 0.1.0
    , updateAction         :: IO a
    -- ^ Action to be performed to get the current value.
    --
    -- Default: does nothing.
    --
    -- @since 0.1.0
    }

mkAutoUpdate :: UpdateSettings a -> IO (IO a)
mkAutoUpdate us = mkAutoUpdateHelper us Nothing

mkAutoUpdateWithModify :: UpdateSettings a -> (a -> IO a) -> IO (IO a)
mkAutoUpdateWithModify us f = mkAutoUpdateHelper us (Just f)

-- | Generate an action which will either read from an automatically
-- updated value, or run the update action in the current thread.
--
-- @since 0.1.0
mkAutoUpdateHelper :: UpdateSettings a -> Maybe (a -> IO a) -> IO (IO a)
mkAutoUpdateHelper us updateActionModify = do
    -- A baton to tell the worker thread to generate a new value.
    needsRunning <- newEmptyMVar

    -- The initial response variable. Response variables allow the requesting
    -- thread to block until a value is generated by the worker thread.
    responseVar0 <- newEmptyMVar

    -- The current value, if available. We start off with a Left value
    -- indicating no value is available, and the above-created responseVar0 to
    -- give a variable to block on.
    currRef <- newIORef $ Left responseVar0

    -- This is used to set a value in the currRef variable when the worker
    -- thread exits. In reality, that value should never be used, since the
    -- worker thread exiting only occurs if an async exception is thrown, which
    -- should only occur if there are no references to needsRunning left.
    -- However, this handler will make error messages much clearer if there's a
    -- bug in the implementation.
    let fillRefOnExit f = do
            eres <- try f
            case eres of
                Left e -> writeIORef currRef $ error $
                    "Control.AutoUpdate.mkAutoUpdate: worker thread exited with exception: "
                    ++ show (e :: SomeException)
                Right () -> writeIORef currRef $ error $
                    "Control.AutoUpdate.mkAutoUpdate: worker thread exited normally, "
                    ++ "which should be impossible due to usage of infinite loop"

    -- fork the worker thread immediately. Note that we mask async exceptions,
    -- but *not* in an uninterruptible manner. This will allow a
    -- BlockedIndefinitelyOnMVar exception to still be thrown, which will take
    -- down this thread when all references to the returned function are
    -- garbage collected, and therefore there is no thread that can fill the
    -- needsRunning MVar.
    --
    -- Note that since we throw away the ThreadId of this new thread and never
    -- calls myThreadId, normal async exceptions can never be thrown to it,
    -- only RTS exceptions.
    mask_ $ void $ forkIO $ fillRefOnExit $ do
        -- This infinite loop makes up out worker thread. It takes an a
        -- responseVar value where the next value should be putMVar'ed to for
        -- the benefit of any requesters currently blocked on it.
        let loop responseVar maybea = do
                -- block until a value is actually needed
                takeMVar needsRunning

                -- new value requested, so run the updateAction
                a <- catchSome $ maybe (updateAction us) id (updateActionModify <*> maybea)

                -- we got a new value, update currRef and lastValue
                writeIORef currRef $ Right a
                putMVar responseVar a

                -- delay until we're needed again
                threadDelay $ updateFreq us

                -- delay's over. create a new response variable and set currRef
                -- to use it, so that the next requester will block on that
                -- variable. Then loop again with the updated response
                -- variable.
                responseVar' <- newEmptyMVar
                writeIORef currRef $ Left responseVar'
                loop responseVar' (Just a)

        -- Kick off the loop, with the initial responseVar0 variable.
        loop responseVar0 Nothing

    return $ do
        mval <- readIORef currRef
        case mval of
            Left responseVar -> do
                -- no current value, force the worker thread to run...
                void $ tryPutMVar needsRunning ()

                -- and block for the result from the worker
                readMVar responseVar
            -- we have a current value, use it
            Right val -> return val

-- | Turn a runtime exception into an impure exception, so that all 'IO'
-- actions will complete successfully. This simply defers the exception until
-- the value is forced.
catchSome :: IO a -> IO a
catchSome act = Control.Exception.catch act $ \e -> return $ throw (e :: SomeException)
