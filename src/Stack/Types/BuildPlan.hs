{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE FlexibleInstances          #-}

{-# LANGUAGE DataKinds                  #-}
-- | Shared types for various stackage packages.
module Stack.Types.BuildPlan
    ( -- * Types
      BuildPlan (..)
    , PackagePlan (..)
    , ExeName (..)
    , SimpleDesc (..)
    , Snapshots (..)
    , DepInfo (..)
    , Component (..)
    , SnapName (..)
    , MiniBuildPlan (..)
    , miniBuildPlanVC
    , MiniPackageInfo (..)
    , CabalFileInfo (..)
    , GitSHA1 (..)
    , renderSnapName
    , parseSnapName
    , SnapshotHash (..)
    , trimmedSnapshotHash
    , ModuleName (..)
    , ModuleInfo (..)
    , moduleInfoVC
    ) where

import           Control.Applicative
import           Control.Arrow ((&&&))
import           Control.DeepSeq (NFData)
import           Control.Exception (Exception)
import           Control.Monad.Catch (MonadThrow, throwM)
import           Data.Aeson (FromJSON (..), FromJSONKey(..), ToJSON (..), ToJSONKey (..), withObject, withText, (.!=), (.:), (.:?), Value (Object))
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Data
import qualified Data.HashMap.Strict as HashMap
import           Data.Hashable (Hashable)
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Store (Store)
import           Data.Store.Version
import           Data.Store.VersionTagged
import           Data.String (IsString)
import           Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8)
import           Data.Text.Read (decimal)
import           Data.Time (Day)
import qualified Distribution.Text as DT
import qualified Distribution.Version as C
import           GHC.Generics (Generic)
import           Prelude -- Fix AMP warning
import           Safe (readMay)
import           Stack.Types.Compiler
import           Stack.Types.FlagName
import           Stack.Types.PackageName
import           Stack.Types.Version

-- | The name of an LTS Haskell or Stackage Nightly snapshot.
data SnapName
    = LTS !Int !Int
    | Nightly !Day
    deriving (Show, Eq, Ord)

data BuildPlan = BuildPlan
    { bpCompilerVersion :: CompilerVersion
    , bpPackages    :: Map PackageName PackagePlan
    }
    deriving (Show, Eq)

instance FromJSON BuildPlan where
    parseJSON = withObject "BuildPlan" $ \o -> do
        Object si <- o .: "system-info"
        ghcVersion <- si .:? "ghc-version"
        compilerVersion <- si .:? "compiler-version"
        bpCompilerVersion <-
            case (ghcVersion, compilerVersion) of
                (Just _, Just _) -> fail "can't have both compiler-version and ghc-version fields"
                (Just ghc, _) -> return (GhcVersion ghc)
                (_, Just compiler) -> return compiler
                _ -> fail "expected field \"ghc-version\" or \"compiler-version\" not present"
        bpPackages <- o .: "packages"
        return BuildPlan {..}

data PackagePlan = PackagePlan
    { ppVersion     :: Version
    , ppCabalFileInfo :: Maybe CabalFileInfo
    , ppFlagOverrides    :: Map FlagName Bool
    , ppHide             :: Bool
    , ppDesc        :: SimpleDesc
    }
    deriving (Show, Eq)

instance FromJSON PackagePlan where
    parseJSON = withObject "PackageBuild" $ \o -> do
        ppVersion <- o .: "version"
        ppCabalFileInfo <- o .:? "cabal-file-info"

        Object constraints <- o .: "constraints"
        ppFlagOverrides <- constraints .: "flags"
        ppHide <- constraints .:? "hide" .!= False

        ppDesc <- o .: "description"
        return PackagePlan {..}

-- | Information on the contents of a cabal file
data CabalFileInfo = CabalFileInfo
    { cfiSize :: !Int
    -- ^ File size in bytes
    , cfiGitSHA1 :: !GitSHA1
    -- ^ 'GitSHA1' of the cabal file contents
    }
    deriving (Show, Eq, Generic)
instance FromJSON CabalFileInfo where
    parseJSON = withObject "CabalFileInfo" $ \o -> do
        cfiSize <- o .: "size"
        cfiHashes <- o .: "hashes"
        cfiGitSHA1 <- fmap (GitSHA1 . encodeUtf8)
                    $ maybe
                        (fail "Could not find GitSHA1")
                        return
                    $ HashMap.lookup ("GitSHA1" :: Text) cfiHashes
        return CabalFileInfo {..}

simpleParse :: (MonadThrow m, DT.Text a, Typeable a) => Text -> m a
simpleParse orig = withTypeRep $ \rep ->
    case DT.simpleParse str of
        Nothing -> throwM (ParseFailedException rep (pack str))
        Just v  -> return v
  where
    str = unpack orig

    withTypeRep :: Typeable a => (TypeRep -> m a) -> m a
    withTypeRep f =
        res
      where
        res = f (typeOf (unwrap res))

        unwrap :: m a -> a
        unwrap _ = error "unwrap"

data BuildPlanTypesException
    = ParseSnapNameException Text
    | ParseFailedException TypeRep Text
    deriving Typeable
instance Exception BuildPlanTypesException
instance Show BuildPlanTypesException where
    show (ParseSnapNameException t) = "Invalid snapshot name: " ++ T.unpack t
    show (ParseFailedException rep t) =
        "Unable to parse " ++ show t ++ " as " ++ show rep

-- | Name of an executable.
newtype ExeName = ExeName { unExeName :: Text }
    deriving (Show, Eq, Ord, Hashable, IsString, Generic, Store, NFData, Data, Typeable, ToJSON, ToJSONKey, FromJSONKey)
instance FromJSON ExeName where
    parseJSON = withText "ExeName" $ return . ExeName

-- | A simplified package description that tracks:
--
-- * Package dependencies
--
-- * Build tool dependencies
--
-- * Provided executables
--
-- It has fully resolved all conditionals
data SimpleDesc = SimpleDesc
    { sdPackages     :: Map PackageName DepInfo
    , sdTools        :: Map ExeName DepInfo
    , sdProvidedExes :: Set ExeName
    , sdModules      :: Set Text
    -- ^ modules exported by the library
    }
    deriving (Show, Eq)
instance Monoid SimpleDesc where
    mempty = SimpleDesc mempty mempty mempty mempty
    mappend (SimpleDesc a b c d) (SimpleDesc w x y z) = SimpleDesc
        (Map.unionWith (<>) a w)
        (Map.unionWith (<>) b x)
        (c <> y)
        (d <> z)
instance FromJSON SimpleDesc where
    parseJSON = withObject "SimpleDesc" $ \o -> do
        sdPackages <- o .: "packages"
        sdTools <- o .: "tools"
        sdProvidedExes <- o .: "provided-exes"
        sdModules <- o .: "modules"
        return SimpleDesc {..}

data DepInfo = DepInfo
    { diComponents :: Set Component
    , diRange      :: VersionRange
    }
    deriving (Show, Eq)

instance Monoid DepInfo where
    mempty = DepInfo mempty C.anyVersion
    DepInfo a x `mappend` DepInfo b y = DepInfo
        (mappend a b)
        (C.intersectVersionRanges x y)
instance FromJSON DepInfo where
    parseJSON = withObject "DepInfo" $ \o -> do
        diComponents <- o .: "components"
        diRange <- o .: "range" >>= either (fail . show) return . simpleParse
        return DepInfo {..}

data Component = CompLibrary
               | CompExecutable
               | CompTestSuite
               | CompBenchmark
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

compToText :: Component -> Text
compToText CompLibrary = "library"
compToText CompExecutable = "executable"
compToText CompTestSuite = "test-suite"
compToText CompBenchmark = "benchmark"

instance FromJSON Component where
    parseJSON = withText "Component" $ \t -> maybe
        (fail $ "Invalid component: " ++ unpack t)
        return
        (HashMap.lookup t comps)
      where
        comps = HashMap.fromList $ map (compToText &&& id) [minBound..maxBound]

-- | Convert a 'SnapName' into its short representation, e.g. @lts-2.8@,
-- @nightly-2015-03-05@.
renderSnapName :: SnapName -> Text
renderSnapName (LTS x y) = T.pack $ concat ["lts-", show x, ".", show y]
renderSnapName (Nightly d) = T.pack $ "nightly-" ++ show d

-- | Parse the short representation of a 'SnapName'.
parseSnapName :: MonadThrow m => Text -> m SnapName
parseSnapName t0 =
    case lts <|> nightly of
        Nothing -> throwM $ ParseSnapNameException t0
        Just sn -> return sn
  where
    lts = do
        t1 <- T.stripPrefix "lts-" t0
        Right (x, t2) <- Just $ decimal t1
        t3 <- T.stripPrefix "." t2
        Right (y, "") <- Just $ decimal t3
        return $ LTS x y
    nightly = do
        t1 <- T.stripPrefix "nightly-" t0
        Nightly <$> readMay (T.unpack t1)

-- | Most recent Nightly and newest LTS version per major release.
data Snapshots = Snapshots
    { snapshotsNightly :: !Day
    , snapshotsLts     :: !(IntMap Int)
    }
    deriving Show
instance FromJSON Snapshots where
    parseJSON = withObject "Snapshots" $ \o -> Snapshots
        <$> (o .: "nightly" >>= parseNightly)
        <*> fmap IntMap.unions (mapM (parseLTS . snd)
                $ filter (isLTS . fst)
                $ HashMap.toList o)
      where
        parseNightly t =
            case parseSnapName t of
                Left e -> fail $ show e
                Right (LTS _ _) -> fail "Unexpected LTS value"
                Right (Nightly d) -> return d

        isLTS = ("lts-" `T.isPrefixOf`)

        parseLTS = withText "LTS" $ \t ->
            case parseSnapName t of
                Left e -> fail $ show e
                Right (LTS x y) -> return $ IntMap.singleton x y
                Right (Nightly _) -> fail "Unexpected nightly value"

-- | A simplified version of the 'BuildPlan' + cabal file.
data MiniBuildPlan = MiniBuildPlan
    { mbpCompilerVersion :: !CompilerVersion
    , mbpPackages :: !(Map PackageName MiniPackageInfo)
    }
    deriving (Generic, Show, Eq, Data, Typeable)
instance Store MiniBuildPlan
instance NFData MiniBuildPlan

miniBuildPlanVC :: VersionConfig MiniBuildPlan
miniBuildPlanVC = storeVersionConfig "mbp-v2" "C8q73RrYq3plf9hDCapjWpnm_yc="

-- | Information on a single package for the 'MiniBuildPlan'.
data MiniPackageInfo = MiniPackageInfo
    { mpiVersion :: !Version
    , mpiFlags :: !(Map FlagName Bool)
    , mpiGhcOptions :: ![Text]
    , mpiPackageDeps :: !(Set PackageName)
    , mpiToolDeps :: !(Set Text)
    -- ^ Due to ambiguity in Cabal, it is unclear whether this refers to the
    -- executable name, the package name, or something else. We have to guess
    -- based on what's available, which is why we store this in an unwrapped
    -- 'Text'.
    , mpiExes :: !(Set ExeName)
    -- ^ Executables provided by this package
    , mpiHasLibrary :: !Bool
    -- ^ Is there a library present?
    , mpiGitSHA1 :: !(Maybe GitSHA1)
    -- ^ An optional SHA1 representation in hex format of the blob containing
    -- the cabal file contents. Useful for grabbing the correct cabal file
    -- revision directly from a Git repo or the 01-index.tar file
    }
    deriving (Generic, Show, Eq, Data, Typeable)
instance Store MiniPackageInfo
instance NFData MiniPackageInfo

-- | A SHA1 hash, but in Git format. This means that the contents are
-- prefixed with @blob@ and the size of the payload before hashing, as
-- Git itself does.
newtype GitSHA1 = GitSHA1 ByteString
    deriving (Generic, Show, Eq, NFData, Store, Data, Typeable, Ord, Hashable)

newtype SnapshotHash = SnapshotHash { unShapshotHash :: ByteString }
    deriving (Generic, Show, Eq)

trimmedSnapshotHash :: SnapshotHash -> ByteString
trimmedSnapshotHash = BS.take 12 . unShapshotHash

newtype ModuleName = ModuleName { unModuleName :: ByteString }
  deriving (Show, Eq, Ord, Generic, Store, NFData, Typeable, Data)

newtype ModuleInfo = ModuleInfo
    { miModules      :: Map ModuleName (Set PackageName)
    }
  deriving (Show, Eq, Ord, Generic, Typeable, Data)
instance Store ModuleInfo
instance NFData ModuleInfo

instance Monoid ModuleInfo where
  mempty = ModuleInfo mempty
  mappend (ModuleInfo x) (ModuleInfo y) =
    ModuleInfo (Map.unionWith Set.union x y)

moduleInfoVC :: VersionConfig ModuleInfo
moduleInfoVC = storeVersionConfig "mi-v2" "8ImAfrwMVmqoSoEpt85pLvFeV3s="
