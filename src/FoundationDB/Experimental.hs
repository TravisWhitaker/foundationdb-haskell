-- | WIP interface for constructing and running transactions.

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards #-}

module FoundationDB.Experimental (
  -- * Initialization
  FDB.withFoundationDB
  , withDatabase
  , FDB.Database
  -- * Transactions
  , Transaction
  , runTransaction
  , get
  , set
  , clear
  , clearRange
  , getKey
  , atomicOp
  , getRange
  , Range(..)
  , RangeResult(..)
  -- * Futures
  , Future
  , await
  -- * Key selectors
  , FDB.KeySelector( LastLessThan
                   , LastLessOrEq
                   , FirstGreaterThan
                   , FirstGreaterOrEq)
  , offset
  -- * Atomic operations
  , AtomicOp(..)
  -- * Errors
  , Error(..)
) where

import Control.Exception
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Except
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader
import Control.Monad.Trans.Resource
import Data.ByteString.Char8 (ByteString)
import Data.Maybe (fromMaybe)

import qualified FoundationDB.Internal.Bindings as FDB

-- TODO: it's still unclear what facilities should be in Bindings and what
-- should be up here. 'fdbEither' and other helpers might work better if they
-- were built into the functions exported from Bindings.

fdbEither :: MonadIO m => m (FDB.CFDBError, a) -> m (Either Error a)
fdbEither f = do
  (err, res) <- f
  if FDB.isError err
    then return $ Left $ toError err
    else return (Right res)

fdbExcept :: (MonadError Error m, MonadIO m)
             => IO (FDB.CFDBError, a) -> m a
fdbExcept x = do
  e <- liftIO $ fdbEither x
  liftEither e

fdbEither' :: MonadIO m => m FDB.CFDBError -> m (Either Error ())
fdbEither' f = do
  err <- f
  if FDB.isError err
    then return $ Left $ toError err
    else return (Right ())

fdbExcept' :: (MonadError Error m, MonadIO m) =>
               IO FDB.CFDBError -> m ()
fdbExcept' x = do
  e <- liftIO $ fdbEither' x
  liftEither e

-- TODO: docs say this is in 2.2.2 of mtl but it's not in the 2.2.2 on stackage.
liftEither :: MonadError e m => Either e a -> m a
liftEither = either throwError return

liftFDBError :: MonadError Error m => Either FDB.CFDBError a -> m a
liftFDBError = either (throwError . toError) return

data TransactionState = TransactionState {cTransaction :: FDB.Transaction}

createTransactionState :: FDB.Database
                       -> ExceptT Error (ResourceT IO) TransactionState
createTransactionState db = do
  (_rk, eTrans) <- allocate (fdbEither $ FDB.databaseCreateTransaction db)
                            (either (const $ return ()) FDB.transactionDestroy)
  liftEither $ fmap TransactionState eTrans

-- TODO: this will be exported to users with a MonadIO instance. At first
-- glance, that seems bad, since runTransaction will eventually be doing auto
-- retries. I see a few options in various DB libraries on Hackage:
-- 1. don't allow IO in transactions at all.
-- 2. don't even create a separate transaction monad; use IO for everything.
-- 3. Export a TransactionT with MonadIO m => MonadIO (TransactionT m)
--    so that users can decide whether they want to deal with the risk.
-- I'm leaning towards 3. We can export both Transaction and TransactionT.
newtype Transaction a = Transaction
  {unTransaction :: ReaderT TransactionState (ExceptT Error (ResourceT IO)) a}
  deriving (Applicative, Functor, Monad, MonadIO)

deriving instance MonadError Error Transaction
deriving instance MonadReader TransactionState Transaction
deriving instance MonadResource Transaction

data Future a = forall b. Future
  { cFuture :: FDB.Future b
  , extractValue :: Transaction a
  }

fromCExtractor :: FDB.Future b
               -> ReleaseKey
               -> Transaction a
               -> Transaction (Future a)
fromCExtractor cFuture rk m =
  return $ Future cFuture $ do
    res <- m
    release rk
    return res

allocFuture :: IO (FDB.Future b)
            -> (FDB.Future b -> Transaction a)
            -> Transaction (Future a)
allocFuture make extract = do
  (rk, future) <- allocate make FDB.futureDestroy
  fromCExtractor future rk (extract future)

-- | Block until a future is ready.
await :: Future a -> Transaction a
await (Future f e) = do
  fdbExcept' $ FDB.futureBlockUntilReady f
  e

commitFuture :: Transaction (Future ())
commitFuture = do
  (TransactionState t) <- ask
  allocFuture (FDB.transactionCommit t) (const $ return ())

-- TODO: interface for snapshot reads.
-- | Get the value of a key. If the key does not exist, returns 'Nothing'.
get :: ByteString -> Transaction (Future (Maybe ByteString))
get key = do
  t <- ask
  allocFuture (FDB.transactionGet (cTransaction t) key False)
              (\f -> liftIO (FDB.futureGetValue f) >>= liftFDBError)

-- | Set a bytestring key to a bytestring value.
set :: ByteString -> ByteString -> Transaction ()
set key val = do
  (TransactionState t) <- ask
  liftIO $ FDB.transactionSet t key val

-- | Delete a key from the DB.
clear :: ByteString -> Transaction ()
clear k = do
  (TransactionState t) <- ask
  liftIO $ FDB.transactionClear t k

-- | @clearRange k l@ deletes all keys in the half-open range [k,l).
clearRange :: ByteString -> ByteString -> Transaction ()
clearRange k l = do
  (TransactionState t) <- ask
  liftIO $ FDB.transactionClearRange t k l

offset :: FDB.KeySelector -> Int -> FDB.KeySelector
offset (FDB.WithOffset n ks) m = FDB.WithOffset (n+m) ks
offset ks n = FDB.WithOffset n ks

getKey :: FDB.KeySelector -> Transaction (Future ByteString)
getKey ks = do
  (TransactionState t) <- ask
  let (k, orEqual, offset) = FDB.keySelectorTuple ks
  allocFuture (FDB.transactionGetKey t k orEqual offset False)
              (\f -> liftIO (FDB.futureGetKey f) >>= liftFDBError)

getKeyAddresses :: ByteString -> Transaction (Future [ByteString])
getKeyAddresses k = do
  (TransactionState t) <- ask
  allocFuture (FDB.transactionGetAddressesForKey t k)
              (\f -> liftIO (FDB.futureGetStringArray f) >>= liftFDBError)

-- | Specifies a range of keys to be iterated over by 'getRange'.
data Range = Range {
  rangeBegin :: FDB.KeySelector
  -- ^ The beginning of the range, including this key.
  , rangeEnd :: FDB.KeySelector
  -- ^ The end of the range, not including this key.
  , rangeLimit :: Maybe Int
  -- ^ If the range contains more than @n@ items, return only @Just n@.
  -- If @Nothing@ is provided, returns the entire range.
  , rangeReverse :: Bool
  -- ^ If 'True', return the range in reverse order.
} deriving (Show, Eq, Ord)

-- | Structure for returning the result of 'getRange' in chunks.
data RangeResult =
  RangeDone [(ByteString, ByteString)]
  | RangeMore [(ByteString, ByteString)] (Future RangeResult)

getRange :: Range
         -> Transaction (Future RangeResult)
getRange Range{..} = do
  (TransactionState t) <- ask
  let (beginK, beginOrEqual, beginOffset) = FDB.keySelectorTuple rangeBegin
  let (endK, endOrEqual, endOffset) = FDB.keySelectorTuple rangeEnd
  let mk = FDB.transactionGetRange t beginK beginOrEqual beginOffset
                                     endK endOrEqual endOffset
                                     (fromMaybe 0 rangeLimit) 0
                                     FDB.StreamingModeIterator
                                     1
                                     False
                                     rangeReverse
  let handler bsel esel i lim fut = do
        --TODO: need to return Vector or Array for efficiency
        (kvs, more) <- liftIO (FDB.futureGetKeyValueArray fut) >>= liftFDBError
        if more
          then do
            -- last is partial, but access guarded by @more@
            let lstK = snd $ last kvs
            let bsel' = if not rangeReverse
                           then FDB.FirstGreaterThan lstK
                           else bsel
            let (beginK', beginOrEqual', beginOffset') = FDB.keySelectorTuple bsel'
            let esel' = if rangeReverse
                           then FDB.FirstGreaterOrEq lstK
                           else esel
            let (endK', endOrEqual', endOffset') = FDB.keySelectorTuple esel'
            let lim' = fmap (\x -> x - (length kvs)) lim
            let mk' = FDB.transactionGetRange t beginK' beginOrEqual' beginOffset'
                                                endK' endOrEqual' endOffset'
                                                (fromMaybe 0 lim') 0
                                                FDB.StreamingModeIterator
                                                (i+1)
                                                False
                                                rangeReverse
            res <- allocFuture mk' (handler bsel' esel' (i+1) lim')
            return $ RangeMore kvs res
          else return $ RangeDone kvs
  allocFuture mk (handler rangeBegin rangeEnd 1 rangeLimit)

data AtomicOp =
  Add
  | And
  | BitAnd
  | Or
  | BitOr
  | Xor
  | BitXor
  | Max
  | Min
  | SetVersionstampedKey
  | SetVersionstampedValue
  | ByteMin
  | ByteMax
  deriving (Enum, Eq, Ord, Show, Read)

toFDBMutationType :: AtomicOp -> FDB.FDBMutationType
toFDBMutationType Add = FDB.MutationTypeAdd
toFDBMutationType And = FDB.MutationTypeAnd
toFDBMutationType BitAnd = FDB.MutationTypeBitAnd
toFDBMutationType Or = FDB.MutationTypeOr
toFDBMutationType BitOr = FDB.MutationTypeBitOr
toFDBMutationType Xor = FDB.MutationTypeXor
toFDBMutationType BitXor = FDB.MutationTypeBitXor
toFDBMutationType Max = FDB.MutationTypeMax
toFDBMutationType Min = FDB.MutationTypeMin
toFDBMutationType SetVersionstampedKey = FDB.MutationTypeSetVersionstampedKey
toFDBMutationType SetVersionstampedValue =
  FDB.MutationTypeSetVersionstampedValue
toFDBMutationType ByteMin = FDB.MutationTypeByteMin
toFDBMutationType ByteMax = FDB.MutationTypeByteMax

atomicOp :: AtomicOp -> ByteString -> ByteString -> Transaction ()
atomicOp op k x = do
  (TransactionState t) <- ask
  liftIO $ FDB.transactionAtomicOp t k x (toFDBMutationType op)

-- TODO: retries. note: need to handle unknown results correctly when retrying.
-- see https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_commit

-- TODO: way for user to abort transactions.

-- | Attempt to commit a transaction against the given database. If an
-- unretryable error occurs, throws an 'Error'. Attempts to retry the
-- transaction for retryable errors.
runTransaction :: FDB.Database -> Transaction a -> IO a
runTransaction db t = do
  res <- runTransaction' db t
  case res of
    Left err -> throwIO err
    Right x -> return x

-- Attempt to commit a transaction against the given database. If an unretryable
-- error occurs, returns 'Left'. Attempts to retry the transaction for retryable
-- errors.
runTransaction' :: FDB.Database -> Transaction a -> IO (Either Error a)
runTransaction' db (Transaction t) = do
  runResourceT $ runExceptT $ do
    trans <- createTransactionState db
    flip runReaderT trans $ do
      res <- t
      commit <- unTransaction $ commitFuture
      unTransaction $ await commit
      return res

-- TODO: withFoundationDB $ withDatabase is ugly.

initCluster :: FilePath -> IO (Either Error FDB.Cluster)
initCluster fp = do
  futureCluster <- FDB.createCluster fp
  runExceptT $ do
    fdbExcept' $ FDB.futureBlockUntilReady futureCluster
    fdbExcept $ FDB.futureGetCluster futureCluster

withCluster :: Maybe FilePath -> (Either Error FDB.Cluster -> IO a) -> IO a
withCluster mfp f =
  bracket (initCluster (fromMaybe "" mfp))
          (either (const (return ())) FDB.clusterDestroy)
          f

initDB :: FDB.Cluster -> IO (Either Error FDB.Database)
initDB cluster = do
  futureDB <- FDB.clusterCreateDatabase cluster
  runExceptT $ do
    fdbExcept' $ FDB.futureBlockUntilReady futureDB
    fdbExcept $ FDB.futureGetDatabase futureDB

withDatabase :: Maybe FilePath -> (Either Error FDB.Database -> IO a) -> IO a
withDatabase fp f = do
  withCluster fp $ \case
    Left err -> f $ Left err
    Right cluster -> bracket (initDB cluster)
                             (either (const (return ())) destroy)
                             f

-- | Errors that can come from the underlying C library.
-- Most error names are self-explanatory.
-- See https://apple.github.io/foundationdb/api-error-codes.html#developer-guide-error-codes
-- for a description of these errors.
data Error =
  OperationFailed
  | TimedOut
  | TransactionTooOld
  | FutureVersion
  | NotCommitted
  | CommitUnknownResult
  | TransactionCanceled
  | TransactionTimedOut
  | TooManyWatches
  | WatchesDisabled
  | AccessedUnreadable
  | DatabaseLocked
  | ClusterVersionChanged
  | ExternalClientAlreadyLoaded
  | OperationCancelled
  | FutureReleased
  | PlatformError
  | LargeAllocFailed
  | PerformanceCounterError
  | IOError
  | FileNotFound
  | BindFailed
  | FileNotReadable
  | FileNotWritable
  | NoClusterFileFound
  | FileTooLarge
  | ClientInvalidOperation
  | CommitReadIncomplete
  | TestSpecificationInvalid
  | KeyOutsideLegalRange
  | InvertedRange
  | InvalidOptionValue
  | InvalidOption
  | NetworkNotSetup
  | NetworkAlreadySetup
  | ReadVersionAlreadySet
  | VersionInvalid
  | RangeLimitsInvalid
  | InvalidDatabaseName
  | AttributeNotFound
  | FutureNotSet
  | FutureNotError
  | UsedDuringCommit
  | InvalidMutationType
  | TransactionInvalidVersion
  | TransactionReadOnly2021
  -- ^ this has the same name as error code 2023, hence the int suffix.
  | EnvironmentVariableNetworkOptionFailed
  | TransactionReadOnly2023
  | IncompatibleProtocolVersion
  | TransactionTooLarge
  | KeyTooLarge
  | ValueTooLarge
  | ConnectionStringInvalid
  | AddressInUse
  | InvalidLocalAddress
  | TLSError
  | UnsupportedOperation
  | APIVersionUnset
  | APIVersionAlreadySet
  | APIVersionInvalid
  | APIVersionNotSupported
  | ExactModeWithoutLimits
  | UnknownError
  | InternalError
  | OtherError {getOtherError :: FDB.CFDBError}
  deriving (Show, Eq, Ord)

instance Exception Error

toError :: FDB.CFDBError -> Error
toError 0 = error "toError called on successful error code"
toError 1000 = OperationFailed
toError 1004 = TimedOut
toError 1007 = TransactionTooOld
toError 1009 = FutureVersion
toError 1020 = NotCommitted
toError 1021 = CommitUnknownResult
toError 1025 = TransactionCanceled
toError 1031 = TransactionTimedOut
toError 1032 = TooManyWatches
toError 1034 = WatchesDisabled
toError 1036 = AccessedUnreadable
toError 1038 = DatabaseLocked
toError 1039 = ClusterVersionChanged
toError 1040 = ExternalClientAlreadyLoaded
toError 1101 = OperationCancelled
toError 1102 = FutureReleased
toError 1500 = PlatformError
toError 1501 = LargeAllocFailed
toError 1502 = PerformanceCounterError
toError 1510 = IOError
toError 1511 = FileNotFound
toError 1512 = BindFailed
toError 1513 = FileNotReadable
toError 1514 = FileNotWritable
toError 1515 = NoClusterFileFound
toError 1516 = FileTooLarge
toError 2000 = ClientInvalidOperation
toError 2002 = CommitReadIncomplete
toError 2003 = TestSpecificationInvalid
toError 2004 = KeyOutsideLegalRange
toError 2005 = InvertedRange
toError 2006 = InvalidOptionValue
toError 2007 = InvalidOption
toError 2008 = NetworkNotSetup
toError 2009 = NetworkAlreadySetup
toError 2010 = ReadVersionAlreadySet
toError 2011 = VersionInvalid
toError 2012 = RangeLimitsInvalid
toError 2013 = InvalidDatabaseName
toError 2014 = AttributeNotFound
toError 2015 = FutureNotSet
toError 2016 = FutureNotError
toError 2017 = UsedDuringCommit
toError 2018 = InvalidMutationType
toError 2020 = TransactionInvalidVersion
toError 2021 = TransactionReadOnly2021
toError 2022 = EnvironmentVariableNetworkOptionFailed
toError 2023 = TransactionReadOnly2023
toError 2100 = IncompatibleProtocolVersion
toError 2101 = TransactionTooLarge
toError 2102 = KeyTooLarge
toError 2103 = ValueTooLarge
toError 2104 = ConnectionStringInvalid
toError 2105 = AddressInUse
toError 2106 = InvalidLocalAddress
toError 2107 = TLSError
toError 2108 = UnsupportedOperation
toError 2200 = APIVersionUnset
toError 2201 = APIVersionAlreadySet
toError 2202 = APIVersionInvalid
toError 2203 = APIVersionNotSupported
toError 2210 = ExactModeWithoutLimits
toError 4000 = UnknownError
toError 4100 = InternalError
toError n = OtherError n

toCFDBError :: Error -> FDB.CFDBError
toCFDBError OperationFailed = 1000
toCFDBError TimedOut = 1004
toCFDBError TransactionTooOld = 1007
toCFDBError FutureVersion = 1009
toCFDBError NotCommitted = 1020
toCFDBError CommitUnknownResult = 1021
toCFDBError TransactionCanceled = 1025
toCFDBError TransactionTimedOut = 1031
toCFDBError TooManyWatches = 1032
toCFDBError WatchesDisabled = 1034
toCFDBError AccessedUnreadable = 1036
toCFDBError DatabaseLocked = 1038
toCFDBError ClusterVersionChanged = 1039
toCFDBError ExternalClientAlreadyLoaded = 1040
toCFDBError OperationCancelled = 1101
toCFDBError FutureReleased = 1102
toCFDBError PlatformError = 1500
toCFDBError LargeAllocFailed = 1501
toCFDBError PerformanceCounterError = 1502
toCFDBError IOError = 1510
toCFDBError FileNotFound = 1511
toCFDBError BindFailed = 1512
toCFDBError FileNotReadable = 1513
toCFDBError FileNotWritable = 1514
toCFDBError NoClusterFileFound = 1515
toCFDBError FileTooLarge = 1516
toCFDBError ClientInvalidOperation = 2000
toCFDBError CommitReadIncomplete = 2002
toCFDBError TestSpecificationInvalid = 2003
toCFDBError KeyOutsideLegalRange = 2004
toCFDBError InvertedRange = 2005
toCFDBError InvalidOptionValue = 2006
toCFDBError InvalidOption = 2007
toCFDBError NetworkNotSetup = 2008
toCFDBError NetworkAlreadySetup = 2009
toCFDBError ReadVersionAlreadySet = 2010
toCFDBError VersionInvalid = 2011
toCFDBError RangeLimitsInvalid = 2012
toCFDBError InvalidDatabaseName = 2013
toCFDBError AttributeNotFound = 2014
toCFDBError FutureNotSet = 2015
toCFDBError FutureNotError = 2016
toCFDBError UsedDuringCommit = 2017
toCFDBError InvalidMutationType = 2018
toCFDBError TransactionInvalidVersion = 2020
toCFDBError TransactionReadOnly2021 = 2021
toCFDBError EnvironmentVariableNetworkOptionFailed = 2022
toCFDBError TransactionReadOnly2023 = 2023
toCFDBError IncompatibleProtocolVersion = 2100
toCFDBError TransactionTooLarge = 2101
toCFDBError KeyTooLarge = 2102
toCFDBError ValueTooLarge = 2103
toCFDBError ConnectionStringInvalid = 2104
toCFDBError AddressInUse = 2105
toCFDBError InvalidLocalAddress = 2106
toCFDBError TLSError = 2107
toCFDBError UnsupportedOperation = 2108
toCFDBError APIVersionUnset = 2200
toCFDBError APIVersionAlreadySet = 2201
toCFDBError APIVersionInvalid = 2202
toCFDBError APIVersionNotSupported = 2203
toCFDBError ExactModeWithoutLimits = 2210
toCFDBError UnknownError = 4000
toCFDBError InternalError = 4100
toCFDBError (OtherError err) = err
