{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, NamedFieldPuns, CPP  #-}
{-# LANGUAGE DeriveGeneric, StandaloneDeriving #-}

module HSBencher.Types
       (
         -- * Benchmark building
         RunFlags, CompileFlags, FilePredicate(..), filePredCheck,
         BuildResult(..), BuildMethod(..),
         mkBenchmark, 
         Benchmark(..), 
         
         -- * Benchmark configuration spaces
         BenchSpace(..), ParamSetting(..),
         enumerateBenchSpace, compileOptsOnly, isCompileTime,
         toCompileFlags, toRunFlags, toEnvVars, toCmdPaths,
         BuildID, makeBuildID,
         DefaultParamMeaning(..),
         
         -- * HSBench Driver Configuration
         Config(..), BenchM,
#ifdef FUSION_TABLES
         FusionConfig(..),
#endif

         -- * Subprocesses and system commands
         CommandDescr(..), RunResult(..), SubProcess(..), LineHarvester(..),

         -- * Benchmark outputs for upload
         BenchmarkResult(..), emptyBenchmarkResult,

         -- * For convenience; large records call for pretty-printing
         doc
       )
       where

import Control.Monad.Reader
import Data.Char
import Data.List
import qualified Data.Map as M
import Data.Maybe (catMaybes)
import Control.Monad (filterM)
import System.FilePath
import System.Directory
import System.Process (CmdSpec(..))
import qualified Data.Set as Set
import qualified Data.ByteString.Char8 as B
import qualified System.IO.Streams as Strm

import Debug.Trace

import Text.PrettyPrint.GenericPretty (Out(doc,docPrec), Generic)

#ifdef FUSION_TABLES
import Network.Google.FusionTables (TableId)
import Network.Google.FusionTables (createTable, listTables, listColumns, insertRows,
                                    TableId, CellType(..), TableMetadata(..))
#endif

----------------------------------------------------------------------------------------------------
-- Benchmark Build Methods
----------------------------------------------------------------------------------------------------

type EnvVars      = [(String,String)]
type RunFlags     = [String]
type CompileFlags = [String]

-- | Maps canonical command names, e.g. 'ghc', to absolute system paths.
type PathRegistry = M.Map String String

-- | A description of a set of files.  The description may take one of multiple
-- forms.
data FilePredicate = 
    WithExtension String -- ^ E.g. ".hs", WITH the dot.
  | IsExactly     String -- ^ E.g. "Makefile"
--   | SatisfiesPredicate (String -> Bool)

  | InDirectoryWithExactlyOne FilePredicate
    -- ^ A common pattern.  For example, we can build a file foo.c, if it lives in a
    -- directory with exactly one "Makefile".

  | PredOr FilePredicate FilePredicate -- ^ Logical or.
  | AnyFile

  -- TODO: Allow arbitrary function predicates also.
 deriving (Show, Generic, Ord, Eq)
-- instance Show FilePredicate where
--   show (WithExtension s) = "<FilePredicate: *."++s++">"    


-- | This function gives meaning to the `FilePred` type.
--   It returns a filepath to signal "True" and Nothing otherwise.
filePredCheck :: FilePredicate -> FilePath -> IO (Maybe FilePath)
filePredCheck pred path =
  let filename = takeFileName path in 
  case pred of
    AnyFile           -> return (Just path)
    IsExactly str     -> return$ if str == filename
                                 then Just path else Nothing
    WithExtension ext -> return$ if takeExtension filename == ext
                                 then Just path else Nothing
    PredOr p1 p2 -> do
      x <- filePredCheck p1 path
      case x of
        Just _  -> return x
        Nothing -> filePredCheck p2 path
    InDirectoryWithExactlyOne p2 -> do
      ls  <- getDirectoryContents (takeDirectory path)
      ls' <- fmap catMaybes $
             mapM (filePredCheck p2) ls
      case ls' of
        [x] -> return (Just$ takeDirectory path </> x)
        _   -> return Nothing

-- instance Show FilePredicate where
--   show (WithExtension s) = "<FilePredicate: *."++s++">"  

-- | The result of doing a build.  Note that `compile` can will throw an exception if compilation fails.
data BuildResult =
    StandAloneBinary FilePath -- ^ This binary can be copied and executed whenever.
  | RunInPlace (RunFlags -> EnvVars -> CommandDescr)
    -- ^ In this case the build return what you need to do the benchmark run, but the
    -- directory contents cannot be touched until after than run is finished.

instance Show BuildResult where
  show (StandAloneBinary p) = "StandAloneBinary "++p
--  show (RunInPlace fn)      = "RunInPlace "++show (fn [] [])
  show (RunInPlace fn)      = "RunInPlace <fn>"

-- | A completely encapsulated method of building benchmarks.  Cabal and Makefiles
-- are two examples of this.  The user may extend it with their own methods.
data BuildMethod =
  BuildMethod
  { methodName :: String          -- ^ Identifies this build method for humans.
--  , buildsFiles :: FilePredicate
--  , canBuild    :: FilePath -> IO Bool
  , canBuild    :: FilePredicate  -- ^ Can this method build a given file/directory?
  , concurrentBuild :: Bool -- ^ More than one build can happen at once.  This
                            -- implies that compile always returns StandAloneBinary.
  , compile :: PathRegistry -> BuildID -> CompileFlags -> FilePath -> BenchM BuildResult
  , clean   :: PathRegistry -> BuildID -> FilePath -> BenchM () -- ^ Clean any left-over build results.
  , setThreads :: Maybe (Int -> [ParamSetting])
                  -- ^ Synthesize a list of compile/runtime settings that
                  -- will control the number of threads.
  }

instance Show BuildMethod where
  show BuildMethod{methodName, canBuild} = "<buildMethod "++methodName++" "++show canBuild ++">"

----------------------------------------------------------------------------------------------------
-- HSBench Configuration
----------------------------------------------------------------------------------------------------

-- | A monad for benchamrking.  This provides access to configuration options, but
-- really, its main purpose is enabling logging.
type BenchM a = ReaderT Config IO a

-- | The global configuration for benchmarking:
data Config = Config 
 { benchlist      :: [Benchmark DefaultParamMeaning]
 , benchsetName   :: Maybe String -- ^ What identifies this set of benchmarks?  Used to create fusion table.
 , benchversion   :: (String, Double) -- ^ benchlist file name and version number (e.g. X.Y)
 , threadsettings :: [Int]  -- ^ A list of #threads to test.  0 signifies non-threaded mode.
 , maxthreads     :: Int
 , trials         :: Int    -- ^ number of runs of each configuration
 , shortrun       :: Bool
 , doClean        :: Bool
 , keepgoing      :: Bool   -- ^ keep going after error
 , pathRegistry   :: PathRegistry -- ^ Paths to executables.
 , hostname       :: String
 , startTime      :: Integer -- ^ Seconds since Epoch. 
 , resultsFile    :: String -- ^ Where to put timing results.
 , logFile        :: String -- ^ Where to put more verbose testing output.

 , gitInfo        :: (String,String,Int) -- ^ Branch, revision hash, depth.

 , buildMethods   :: [BuildMethod] -- ^ Starts with cabal/make/ghc, can be extended by user.
   
 -- These are all LINES-streams (implicit newlines).
 , logOut         :: Strm.OutputStream B.ByteString
 , resultsOut     :: Strm.OutputStream B.ByteString
 , stdOut         :: Strm.OutputStream B.ByteString
   -- A set of environment variable configurations to test
 , envs           :: [[(String, String)]]

 , argsBeforeFlags :: Bool -- ^ A global setting to control whether executables are given
                           -- their 'flags/params' after their regular arguments.
                           -- This is here because some executables don't use proper command line parsing.
 , harvesters :: (LineHarvester, Maybe LineHarvester) -- ^ Line harvesters for SELFTIMED and productivity lines.
 , doFusionUpload  :: Bool
#ifdef FUSION_TABLES
 , fusionConfig   :: FusionConfig
#endif
 }
 deriving Show

#ifdef FUSION_TABLES
data FusionConfig = 
  FusionConfig
  { fusionTableID  :: Maybe TableId -- ^ This must be Just whenever doFusionUpload is true.
  , fusionClientID :: Maybe String
  , fusionClientSecret :: Maybe String
--  , fusionUpload   :: Maybe FusionInfo
  }
  deriving Show
#endif

instance Show (Strm.OutputStream a) where
  show _ = "<OutputStream>"

----------------------------------------------------------------------------------------------------
-- Configuration Spaces
----------------------------------------------------------------------------------------------------

-- type BenchFile = [BenchStmt]

data Benchmark a = Benchmark
 { target  :: FilePath      -- ^ The target file or direcotry.
 , cmdargs :: [String]      -- ^ Command line argument to feed the benchmark executable.
 , configs :: BenchSpace a  -- ^ The configration space to iterate over.
 } deriving (Eq, Show, Ord, Generic)


-- | Make a Benchmark data structure given the core, required set of fields, and uses
-- defaults to fill in the rest.  Takes target, cmdargs, configs.
mkBenchmark :: FilePath -> [String] -> BenchSpace a -> Benchmark a 
mkBenchmark  target  cmdargs configs = 
  Benchmark {target, cmdargs, configs}


-- | A datatype for describing (generating) benchmark configuration spaces.
--   This is accomplished by nested conjunctions and disjunctions.
--   For example, varying threads from 1-32 would be a 32-way Or.  Combining that
--   with profiling on/off (product) would create a 64-config space.
--
--   While the ParamSetting provides an *implementation* of the behavior, this
--   datatype can also be decorated with a (more easily machine readable) meaning of
--   the corresponding setting.  For example, indicating that the setting controls
--   the number of threads.
data BenchSpace meaning = And [BenchSpace meaning]
                        | Or  [BenchSpace meaning]
                        | Set meaning ParamSetting 
 deriving (Show,Eq,Ord,Read, Generic)

data DefaultParamMeaning
  = Threads Int    -- ^ Set the number of threads.
  | Variant String -- ^ Which scheduler/implementation/etc.
  | NoMeaning
 deriving (Show,Eq,Ord,Read, Generic)

-- | Exhaustively compute all configurations described by a benchmark configuration space.
enumerateBenchSpace :: BenchSpace a -> [ [(a,ParamSetting)] ] 
enumerateBenchSpace bs =
  case bs of
    Set m p -> [ [(m,p)] ]
    Or ls -> concatMap enumerateBenchSpace ls
    And ls -> loop ls
  where
    loop [] = [ [] ]  -- And [] => one config
    loop [lst] = enumerateBenchSpace lst
    loop (hd:tl) =
      let confs = enumerateBenchSpace hd in
      [ c++r | c <- confs
             , r <- loop tl ]

-- | Is it a setting that affects compile time?
isCompileTime :: ParamSetting -> Bool
isCompileTime CompileParam{} = True
isCompileTime CmdPath     {} = True
isCompileTime RuntimeParam{} = False
isCompileTime RuntimeEnv  {} = False

toCompileFlags :: [(a,ParamSetting)] -> CompileFlags
toCompileFlags [] = []
toCompileFlags ((_,CompileParam s1) : tl) = s1 : toCompileFlags tl
toCompileFlags (_ : tl)                   =      toCompileFlags tl

toRunFlags :: [(a,ParamSetting)] -> RunFlags
toRunFlags [] = []
toRunFlags ((_,RuntimeParam s1) : tl) = (s1) : toRunFlags tl
toRunFlags (_ : tl)                  =            toRunFlags tl

toCmdPaths :: [(a,ParamSetting)] -> [(String,String)]
toCmdPaths = catMaybes . map fn
 where
   fn (_,CmdPath c p) = Just (c,p)
   fn _               = Nothing

toEnvVars :: [(a,ParamSetting)] -> [(String,String)]
toEnvVars [] = []
toEnvVars ((_,RuntimeEnv s1 s2)
           : tl) = (s1,s2) : toEnvVars tl
toEnvVars (_ : tl)                =           toEnvVars tl


-- | A BuildID should uniquely identify a particular (compile-time) configuration,
-- but consist only of characters that would be reasonable to put in a filename.
-- This is used to keep build results from colliding.
type BuildID = String

-- | Performs a simple reformatting (stripping disallowed characters) to create a
-- build ID corresponding to a set of compile flags.  To make it unique we also
-- append the target path.
makeBuildID :: FilePath -> CompileFlags -> BuildID
makeBuildID target strs =
  encodedTarget ++ 
  (intercalate "_" $
   map (filter charAllowed) strs)
 where
  charAllowed = isAlphaNum
  encodedTarget = map (\ c -> if charAllowed c then c else '_') target

-- | Strip all runtime options, leaving only compile-time options.  This is useful
--   for figuring out how many separate compiles need to happen.
compileOptsOnly :: BenchSpace a -> BenchSpace a 
compileOptsOnly x =
  case loop x of
    Nothing -> And []
    Just b  -> b
 where
   loop bs = 
     case bs of
       And ls -> mayb$ And$ catMaybes$ map loop ls
       Or  ls -> mayb$ Or $ catMaybes$ map loop ls
       Set m (CompileParam {}) -> Just bs
       Set m (CmdPath      {}) -> Just bs -- These affect compilation also...
       Set _ _                 -> Nothing
   mayb (And []) = Nothing
   mayb (Or  []) = Nothing
   mayb x        = Just x

test1 = Or (map (Set () . RuntimeEnv "CILK_NPROCS" . show) [1..32])
test2 = Or$ map (Set () . RuntimeParam . ("-A"++)) ["1M", "2M"]
test3 = And [test1, test2]

-- | Different types of parameters that may be set or varied.
data ParamSetting 
  = RuntimeParam String -- ^ String contains runtime options, expanded and tokenized by the shell.
  | CompileParam String -- ^ String contains compile-time options, expanded and tokenized by the shell.
  | RuntimeEnv   String String -- ^ The name of the env var and its value, respectively.
                               --   For now Env Vars ONLY affect runtime.
  | CmdPath      String String -- ^ Takes CMD PATH, and establishes a benchmark-private setting to use PATH for CMD.
                               --   For example `CmdPath "ghc" "ghc-7.6.3"`.
-- | Threads Int -- ^ Shorthand: builtin support for changing the number of
    -- threads across a number of separate build methods.
 deriving (Show, Eq, Read, Ord, Generic)

----------------------------------------------------------------------------------------------------
-- Subprocesses and system commands
----------------------------------------------------------------------------------------------------

-- | A self-contained description of a runnable command.  Similar to
-- System.Process.CreateProcess but slightly simpler.
data CommandDescr =
  CommandDescr
  { command :: CmdSpec            -- ^ Executable and arguments
  , envVars :: [(String, String)] -- ^ Environment variables to APPEND to current env.
  , timeout :: Maybe Double       -- ^ Optional timeout in seconds.
  , workingDir :: Maybe FilePath  -- ^ Optional working directory to switch to before
                                  --   running command.
  }
 deriving (Show,Eq,Ord,Read,Generic)

-- Umm... these should be defined in base:
deriving instance Eq   CmdSpec   
deriving instance Show CmdSpec
deriving instance Ord  CmdSpec
deriving instance Read CmdSpec   

-- | Measured results from running a subprocess (benchmark).
data RunResult =
    RunCompleted { realtime     :: Double       -- ^ Benchmark time in seconds, may be different than total process time.
                 , productivity :: Maybe Double -- ^ Seconds
                 }
  | TimeOut
  | ExitError Int -- ^ Contains the returned error code.
 deriving (Eq,Show)

-- | A running subprocess.
data SubProcess =
  SubProcess
  { wait :: IO RunResult
  , process_out  :: Strm.InputStream B.ByteString -- ^ A stream of lines.
  , process_err  :: Strm.InputStream B.ByteString -- ^ A stream of lines.
  }

instance Out ParamSetting
instance Out FilePredicate
instance Out DefaultParamMeaning
instance Out a => Out (BenchSpace a)
instance Out a => Out (Benchmark a)

instance (Out k, Out v) => Out (M.Map k v) where
  docPrec n m = docPrec n $ M.toList m
  doc         = docPrec 0 


-- | Things like "SELFTIMED" that should be monitored.
-- type Tags = [String]

newtype LineHarvester = LineHarvester (B.ByteString -> Maybe Double)
instance Show LineHarvester where
  show _ = "<LineHarvester>"

----------------------------------------------------------------------------------------------------
-- Benchmark Results Upload
----------------------------------------------------------------------------------------------------

-- | This contains all the contextual information for a single benchmark run, which
--   makes up a "row" in a table of benchmark results.
--   Note that multiple "trials" (actual executions) go into a single BenchmarkResult
data BenchmarkResult =
  BenchmarkResult
  { _PROGNAME :: String
  , _VARIANT  :: String
  , _ARGS     :: [String]
  , _HOSTNAME :: String
  , _RUNID    :: String
  , _THREADS  :: Int
  , _DATETIME :: String -- Datetime
  , _MINTIME    ::  Double
  , _MEDIANTIME ::  Double
  , _MAXTIME    ::  Double
  , _MINTIME_PRODUCTIVITY    ::  Maybe Double
  , _MEDIANTIME_PRODUCTIVITY ::  Maybe Double
  , _MAXTIME_PRODUCTIVITY    ::  Maybe Double
  , _ALLTIMES      ::  String
  , _TRIALS        ::  Int
  , _COMPILER      :: String
  , _COMPILE_FLAGS :: String
  , _RUNTIME_FLAGS :: String
  , _ENV_VARS      :: String
  , _BENCH_VERSION ::  String
  , _BENCH_FILE ::  String
  , _UNAME      :: String
  , _PROCESSOR  :: String
  , _TOPOLOGY   :: String
  , _GIT_BRANCH :: String
  , _GIT_HASH   :: String
  , _GIT_DEPTH  :: Int
  , _WHO        :: String
  , _ETC_ISSUE  :: String
  , _LSPCI      :: String
  , _FULL_LOG   :: String
  }

-- | A default value, useful for filling in only the fields that are relevant to a particular benchmark.
emptyBenchmarkResult :: BenchmarkResult
emptyBenchmarkResult = BenchmarkResult
  { _PROGNAME = ""
  , _VARIANT  = ""
  , _ARGS     = []
  , _HOSTNAME = ""
  , _RUNID    = ""
  , _THREADS  = 0
  , _DATETIME = "" 
  , _MINTIME    =  0.0
  , _MEDIANTIME =  0.0
  , _MAXTIME    =  0.0
  , _MINTIME_PRODUCTIVITY    =  Nothing
  , _MEDIANTIME_PRODUCTIVITY =  Nothing
  , _MAXTIME_PRODUCTIVITY    =  Nothing
  , _ALLTIMES      =  ""
  , _TRIALS        =  1
  , _COMPILER      = ""
  , _COMPILE_FLAGS = ""
  , _RUNTIME_FLAGS = ""
  , _ENV_VARS      = ""
  , _BENCH_VERSION =  ""
  , _BENCH_FILE =  ""
  , _UNAME      = ""
  , _PROCESSOR  = ""
  , _TOPOLOGY   = ""
  , _GIT_BRANCH = ""
  , _GIT_HASH   = ""
  , _GIT_DEPTH  = -1
  , _WHO        = ""
  , _ETC_ISSUE  = ""
  , _LSPCI      = ""
  , _FULL_LOG   = ""
  }

