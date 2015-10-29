{-# LANGUAGE RecordWildCards, NamedFieldPuns,
             DeriveGeneric, DeriveDataTypeable, 
             ScopedTypeVariables #-}

-- | Planning how to build everything in a project.
--
module Distribution.Client.ProjectPlanning (
    -- * elaborated install plan types
    ElaboratedInstallPlan,
    ElaboratedConfiguredPackage(..),
    ElaboratedSharedConfig(..),
    ElaboratedReadyPackage,
    BuildStyle(..),
    CabalFileText,

    --TODO: [code cleanup] these types should live with execution, not with
    --      plan definition. Need to better separate InstallPlan definition.
    GenericBuildResult(..),
    BuildResult,
    BuildSuccess(..),
    BuildFailure(..),
    DocsResult(..),
    TestsResult(..),

    rebuildInstallPlan,
    
    -- * Setup.hs CLI flags for building
    setupHsScriptOptions,
    setupHsConfigureFlags,
    setupHsBuildFlags,
    setupHsCopyFlags,
    setupHsRegisterFlags,

    packageHashInputs,
    
    -- TODO: [code cleanup] utils that should live in some shared place?
    createPackageDBIfMissing
  ) where

import           Distribution.Client.PackageHash
import           Distribution.Client.RebuildMonad
import           Distribution.Client.ProjectConfig

import           Distribution.Client.Types hiding (BuildResult, BuildSuccess(..), BuildFailure(..), DocsResult(..), TestsResult(..))
import           Distribution.Client.InstallPlan
                   ( GenericInstallPlan, InstallPlan )
import qualified Distribution.Client.InstallPlan as InstallPlan
import           Distribution.Client.Dependency
import           Distribution.Client.Dependency.Types
import qualified Distribution.Client.ComponentDeps as CD
import           Distribution.Client.ComponentDeps (ComponentDeps)
import qualified Distribution.Client.IndexUtils as IndexUtils
import           Distribution.Client.Targets
import           Distribution.Client.DistDirLayout
import           Distribution.Client.SetupWrapper
import           Distribution.Client.JobControl
import           Distribution.Client.HttpUtils
import           Distribution.Client.FetchUtils
import           Distribution.Client.Setup hiding (packageName, cabalVersion)
import           Distribution.Utils.NubList (toNubList)

import           Distribution.Package
import           Distribution.System
import qualified Distribution.PackageDescription as Cabal
import qualified Distribution.PackageDescription as PD
import qualified Distribution.PackageDescription.Parse as Cabal
import           Distribution.InstalledPackageInfo (InstalledPackageInfo)
import qualified Distribution.InstalledPackageInfo as Installed
import           Distribution.Simple.PackageIndex (InstalledPackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import           Distribution.Simple.Compiler hiding (Flag)
import qualified Distribution.Simple.GHC   as GHC   --TODO: [code cleanup] eliminate
import qualified Distribution.Simple.GHCJS as GHCJS --TODO: [code cleanup] eliminate
import           Distribution.Simple.Program
import           Distribution.Simple.Program.Db
import           Distribution.Simple.Program.Find
import qualified Distribution.Simple.Setup as Cabal
import           Distribution.Simple.Setup (Flag, toFlag, flagToMaybe, fromFlag, fromFlagOrDefault)
import qualified Distribution.Simple.Configure as Cabal
import qualified Distribution.Simple.Register as Cabal
import qualified Distribution.Simple.InstallDirs as InstallDirs
import           Distribution.Simple.InstallDirs (PathTemplate)
import           Distribution.Simple.BuildTarget

import           Distribution.Simple.Utils hiding (matchFileGlob)
import           Distribution.Version
import           Distribution.Verbosity
import           Distribution.Text

import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.ByteString.Lazy as LBS

import           Control.Applicative
import           Control.Monad
import           Control.Monad.State as State
import           Control.Exception
import           Data.List
import           Data.Either
import           Data.Maybe
import           Data.Monoid

import           Data.Binary
import           GHC.Generics (Generic)
import           Data.Typeable (Typeable)

import           System.FilePath


------------------------------------------------------------------------------
-- * Elaborated install plan
------------------------------------------------------------------------------

-- "Elaborated" -- worked out with great care and nicety of detail;
--                 executed with great minuteness: elaborate preparations;
--                 elaborate care.
--
-- So here's the idea:
--
-- Rather than a miscellaneous collection of 'ConfigFlags', 'InstallFlags' etc
-- all passed in as separate args and which are then further selected,
-- transformed etc during the execution of the build. Instead we construct
-- an elaborated install plan that includes everything we will need, and then
-- during the execution of the plan we do as little transformation of this
-- info as possible.
--
-- So we're trying to split the work into two phases: construction of the
-- elaborated install plan (which as far as possible should be pure) and
-- then simple execution of that plan without any smarts, just doing what the
-- plan says to do.
--
-- So that means we need a representation of this fully elaborated install
-- plan. The representation consists of two parts:
--
-- * A 'ElaboratedInstallPlan'. This is a 'GenericInstallPlan' with a
--   representation of source packages that includes a lot more detail about
--   that package's individual configuration
--
-- * A 'ElaboratedSharedConfig'. Some package configuration is the same for
--   every package in a plan. Rather than duplicate that info every entry in
--   the 'GenericInstallPlan' we keep that separately.
--
-- The division between the shared and per-package config is /not set in stone
-- for all time/. For example if we wanted to generalise the install plan to
-- describe a situation where we want to build some packages with GHC and some
-- with GHCJS then the platform and compiler would no longer be shared between
-- all packages but would have to be per-package (probably with some sanity
-- condition on the graph structure).
--

-- | The combination of an elaborated install plan plus a
-- 'ElaboratedSharedConfig' contains all the details necessary to be able
-- to execute the plan without having to make further policy decisions.
--
-- It does not include dynamic elements such as resources (such as http
-- connections).
--
type ElaboratedInstallPlan
   = GenericInstallPlan InstalledPackageInfo
                        ElaboratedConfiguredPackage
                        BuildSuccess BuildFailure

type SolverInstallPlan
   = InstallPlan --TODO: [code cleanup] redefine locally or move def to solver interface

--TODO: [code cleanup] decide if we really need this, there's not much in it, and in principle
--      even platform and compiler could be different if we're building things
--      like a server + client with ghc + ghcjs
data ElaboratedSharedConfig
   = ElaboratedSharedConfig {

       pkgConfigPlatform         :: Platform,
       pkgConfigCompiler         :: Compiler, --TODO: [code cleanup] replace with CompilerInfo
       pkgConfigProgramDb        :: ProgramDb --TODO: [code cleanup] no Eq instance
       --TODO: [code cleanup] binary instance does not preserve the prog paths
       --      perhaps should keep the configured progs separately
     }
  deriving (Show, Generic)

instance Binary ElaboratedSharedConfig

data ElaboratedConfiguredPackage
   = ElaboratedConfiguredPackage {

       pkgInstalledId :: InstalledPackageId,
       pkgSourceId    :: PackageId,

       -- | TODO: [code cleanup] we don't need this, just a few bits from it:
       --   build type, spec version
       pkgDescription :: Cabal.GenericPackageDescription,

       -- | A total flag assignment for the package
       pkgFlagAssignment   :: Cabal.FlagAssignment,

       -- | Which optional stanzas are enabled (testsuites, benchmarks)
       pkgTestsuitesEnable :: Bool,
       pkgBenchmarksEnable :: Bool,
       pkgEnabledStanzas   :: [OptionalStanza], --TODO: [required feature] eliminate 

       -- | The exact dependencies (on other plan packages)
       --
       pkgDependencies     :: ComponentDeps [ConfiguredId],

       -- | Where the package comes from, e.g. tarball, local dir etc. This
       --   is not the same as where it may be unpacked to for the build.
       pkgSourceLocation :: PackageLocation (Maybe FilePath),

       pkgSourceHash     :: Maybe PackageSourceHash,

       --pkgSourceDir ? -- currently passed in later because they can use temp locations
       --pkgBuildDir  ? -- but could in principle still have it here, with optional instr to use temp loc

       pkgBuildStyle             :: BuildStyle,

       pkgSetupPackageDBStack    :: PackageDBStack,
       pkgBuildPackageDBStack    :: PackageDBStack,
       pkgRegisterPackageDBStack :: PackageDBStack,

       -- | The package contains a library and so must be registered
       pkgRequiresRegistration :: Bool,
       pkgDescriptionOverride  :: Maybe CabalFileText,

       pkgVanillaLib           :: Bool,
       pkgSharedLib            :: Bool,
       pkgDynExe               :: Bool,
       pkgGHCiLib              :: Bool,
       pkgProfLib              :: Bool,
       pkgProfExe              :: Bool,
       pkgProfLibDetail        :: ProfDetailLevel,
       pkgProfExeDetail        :: ProfDetailLevel,
       pkgCoverage             :: Bool,
       pkgOptimization         :: OptimisationLevel,
       pkgSplitObjs            :: Bool,
       pkgStripLibs            :: Bool,
       pkgStripExes            :: Bool,
       pkgDebugInfo            :: DebugInfoLevel,

       pkgConfigureScriptArgs   :: [String],
       pkgExtraLibDirs          :: [FilePath],
       pkgExtraIncludeDirs      :: [FilePath],
       pkgProgPrefix            :: Maybe PathTemplate,
       pkgProgSuffix            :: Maybe PathTemplate,

       pkgInstallDirs           :: InstallDirs.InstallDirs FilePath,

       -- Setup.hs related things:

       -- | One of four modes for how we build and interact with the Setup.hs
       -- script, based on whether it's a build-type Custom, with or without
       -- explicit deps and the cabal spec version the .cabal file needs.
       pkgSetupScriptStyle      :: SetupScriptStyle,

       -- | The version of the Cabal command line interface that we are using
       -- for this package. This is typically the version of the Cabal lib
       -- that the Setup.hs is built against.
       pkgSetupScriptCliVersion :: Version,

       -- Build time related:
       pkgBuildTargets          :: Maybe [BuildTarget]
     }
  deriving (Eq, Show, Generic)

instance Binary ElaboratedConfiguredPackage

instance Package ElaboratedConfiguredPackage where
  packageId = pkgSourceId

instance HasInstalledPackageId ElaboratedConfiguredPackage where
  installedPackageId = pkgInstalledId

instance PackageFixedDeps ElaboratedConfiguredPackage where
  depends = fmap (map installedPackageId) . pkgDependencies

-- | This is used in the install plan to indicate how the package will be
-- built.
--
data BuildStyle =
    -- | The classic approach where the package is built, then the files
    -- installed into some location and the result registered in a package db.
    --
    -- If the package came from a tarball then it's built in a temp dir and
    -- the results discarded.
    BuildAndInstall

    -- | The package is built, but the files are not installed anywhere,
    -- rather the build dir is kept and the package is registered inplace.
    --
    -- Such packages can still subsequently be installed.
    --
    -- Typically 'BuildAndInstall' packages will only depend on other
    -- 'BuildAndInstall' style packages and not on 'BuildInplaceOnly' ones.
    --
  | BuildInplaceOnly
  deriving (Eq, Show, Generic)

instance Binary BuildStyle

type CabalFileText = LBS.ByteString

type ElaboratedReadyPackage = GenericReadyPackage ElaboratedConfiguredPackage
                                                  InstalledPackageInfo

--TODO: [code cleanup] this duplicates the InstalledPackageInfo quite a bit in an install plan
-- because the same ipkg is used by many packages. So the binary file will be big.
-- Could we keep just (ipkgid, deps) instead of the whole InstalledPackageInfo?
-- or transform to a shared form when serialising / deserialising

data GenericBuildResult ipkg iresult ifailure
                  = BuildFailure ifailure
                  | BuildSuccess (Maybe ipkg) iresult
  deriving (Eq, Show, Generic)

instance (Binary ipkg, Binary iresult, Binary ifailure) =>
         Binary (GenericBuildResult ipkg iresult ifailure)

type BuildResult  = GenericBuildResult InstalledPackageInfo 
                                       BuildSuccess BuildFailure

data BuildSuccess = BuildOk Bool DocsResult TestsResult
  deriving (Eq, Show, Generic)

data DocsResult  = DocsNotTried  | DocsFailed  | DocsOk
  deriving (Eq, Show, Generic)

data TestsResult = TestsNotTried | TestsOk
  deriving (Eq, Show, Generic)

data BuildFailure = PlanningFailed              --TODO: [required eventually] not yet used
                  | DependentFailed PackageId
                  | DownloadFailed  String      --TODO: [required eventually] not yet used
                  | UnpackFailed    String      --TODO: [required eventually] not yet used
                  | ConfigureFailed String
                  | BuildFailed     String
                  | TestsFailed     String      --TODO: [required eventually] not yet used
                  | InstallFailed   String
  deriving (Eq, Show, Typeable, Generic)

instance Exception BuildFailure

instance Binary BuildFailure
instance Binary BuildSuccess
instance Binary DocsResult
instance Binary TestsResult


------------------------------------------------------------------------------
-- * Deciding what to do: making an 'ElaboratedInstallPlan'
------------------------------------------------------------------------------

type CliConfig = ( ProjectConfigSolver
                 , PackageConfigShared
                 , PackageConfig
                 )

rebuildInstallPlan :: Verbosity
                   -> FilePath -> DistDirLayout -> CabalDirLayout
                   -> CliConfig
                   -> IO ( ElaboratedInstallPlan
                         , ElaboratedSharedConfig
                         , ProjectConfig )
rebuildInstallPlan verbosity
                   projectRootDir
                   distDirLayout@DistDirLayout{..}
                   cabalDirLayout@CabalDirLayout{..} = \cliConfig ->
    runRebuild $ do
    progsearchpath <- liftIO $ getSystemSearchPath

    -- The overall improved plan is cached
    rerunIfChanged verbosity projectRootDir fileMonitorImprovedPlan
                   -- react to changes in command line args and the path
                   (cliConfig, progsearchpath) $ do

      -- And so is the elaborated plan that the improved plan based on
      (elaboratedPlan, elaboratedShared,
       projectConfig) <-
        rerunIfChanged verbosity projectRootDir fileMonitorElaboratedPlan
                       (cliConfig, progsearchpath) $ do

          projectConfig <- phaseReadProjectConfig cliConfig
          localPackages <- phaseReadLocalPackages projectConfig
          compilerEtc   <- phaseConfigureCompiler projectConfig
          solverPlan    <- phaseRunSolver         projectConfig compilerEtc
                                                  localPackages
          (elaboratedPlan,
           elaboratedShared) <- phaseElaboratePlan projectConfig compilerEtc
                                                   solverPlan localPackages

          return (elaboratedPlan, elaboratedShared,
                  projectConfig)

      -- The improved plan changes each time we install something, whereas
      -- the underlying elaborated plan only changes when input config
      -- changes, so it's worth caching them separately.
      improvedPlan <- phaseImprovePlan elaboratedPlan elaboratedShared
      return (improvedPlan, elaboratedShared, projectConfig)

  where
    fileMonitorCompiler       = FileMonitorCacheFile (distProjectCacheFile "compiler")
    fileMonitorSolverPlan     = FileMonitorCacheFile (distProjectCacheFile "solver-plan")
    fileMonitorSourceHashes   = FileMonitorCacheFile (distProjectCacheFile "source-hashes")
    fileMonitorElaboratedPlan = FileMonitorCacheFile (distProjectCacheFile "elaborated-plan")
    fileMonitorImprovedPlan   = FileMonitorCacheFile (distProjectCacheFile "improved-plan")

    -- Read the cabal.project (or implicit config) and combine it with
    -- arguments from the command line
    --
    phaseReadProjectConfig :: CliConfig -> Rebuild ProjectConfig
    phaseReadProjectConfig ( cliConfigSolver
                           , cliConfigAllPackages
                           , cliConfigLocalPackages
                           ) = do
      liftIO $ do
        info verbosity "Project settings changed, reconfiguring..."
        createDirectoryIfMissingVerbose verbosity False distDirectory
        createDirectoryIfMissingVerbose verbosity False distProjectCacheDirectory

      readProjectConfig projectRootDir
                        cliConfigSolver
                        cliConfigAllPackages
                        cliConfigLocalPackages


    -- Look for all the cabal packages in the project
    -- some of which may be local src dirs, tarballs etc
    --
    phaseReadLocalPackages :: ProjectConfig
                           -> Rebuild [PackageSpecifier SourcePackage]
    phaseReadLocalPackages projectConfig = do

      localCabalFiles <- findProjectCabalFiles projectConfig
      mapM (readSourcePackage verbosity) localCabalFiles


    -- Configure the compiler we're using.
    --
    -- This is moderately expensive and doesn't change that often so we cache
    -- it independently.
    --
    phaseConfigureCompiler :: ProjectConfig
                           -> Rebuild (Compiler, Platform, ProgramDb)
    phaseConfigureCompiler ProjectConfig{projectConfigAllPackages} = do
        progsearchpath <- liftIO $ getSystemSearchPath
        rerunIfChanged verbosity projectRootDir fileMonitorCompiler
                       (hcFlavor, hcPath, hcPkg, progsearchpath) $ do

          liftIO $ info verbosity "Compiler settings changed, reconfiguring..."
          result@(_, _, progdb) <- liftIO $
            Cabal.configCompilerEx
              hcFlavor hcPath hcPkg
              defaultProgramDb verbosity

          monitorFiles (programsMonitorFiles progdb)

          return result
      where
        hcFlavor = flagToMaybe packageConfigHcFlavor
        hcPath   = flagToMaybe packageConfigHcPath
        hcPkg    = flagToMaybe packageConfigHcPkg
        PackageConfigShared {
          packageConfigHcFlavor,
          packageConfigHcPath,
          packageConfigHcPkg
        }        = projectConfigAllPackages


    -- Run the solver to get the initial install plan.
    -- This is expensive so we cache it independently.
    --
    phaseRunSolver :: ProjectConfig
                   -> (Compiler, Platform, ProgramDb)
                   -> [PackageSpecifier SourcePackage]
                   -> Rebuild SolverInstallPlan
    phaseRunSolver ProjectConfig{projectConfigSolver}
                   (compiler, platform, progdb)
                   localPackages =
        rerunIfChanged verbosity projectRootDir fileMonitorSolverPlan
                       (projectConfigSolver, cabalPackageCacheDirectory,
                        localPackages,
                        compiler, platform, programsDbSignature progdb) $ do
          
          installedPkgIndex <- getInstalledPackages verbosity
                                                    compiler progdb platform
                                                    corePackageDbs
          sourcePkgDb       <- getSourcePackages    verbosity repos

          liftIO $ do
            solver <- chooseSolver verbosity solverpref (compilerInfo compiler)

            notice verbosity "Resolving dependencies..."
            foldProgress logMsg die return $
              planPackages compiler platform solver projectConfigSolver
                           installedPkgIndex sourcePkgDb
                           localPackages
      where
        corePackageDbs = [GlobalPackageDB]
        repos          = projectConfigRepos cabalPackageCacheDirectory
                                            projectConfigSolver
        solverpref     = fromFlag projectConfigSolverSolver
        logMsg message rest = debugNoWrap verbosity message >> rest

        ProjectConfigSolver {projectConfigSolverSolver} = projectConfigSolver


    -- Elaborate the solver's install plan to get a fully detailed plan. This
    -- version of the plan has the final nix-style hashed ids.
    --
    phaseElaboratePlan :: ProjectConfig
                       -> (Compiler, Platform, ProgramDb)
                       -> SolverInstallPlan
                       -> [PackageSpecifier SourcePackage]
                       -> Rebuild ( ElaboratedInstallPlan
                                  , ElaboratedSharedConfig )
    phaseElaboratePlan ProjectConfig {
                         projectConfigAllPackages,
                         projectConfigLocalPackages,
                         projectConfigSpecificPackage,
                         projectConfigBuildOnly
                       }
                       (compiler, platform, progdb)
                       solverPlan localPackages = do

        liftIO $ debug verbosity "Elaborating the install plan..."

        sourcePackageHashes <-
          rerunIfChanged verbosity projectRootDir fileMonitorSourceHashes
                         (map packageId $ InstallPlan.toList solverPlan) $
            getPackageSourceHashes verbosity mkTransport solverPlan

        defaultInstallDirs <- liftIO $ userInstallDirTemplates compiler
        return $
          elaborateInstallPlan
            platform compiler progdb
            distDirLayout
            cabalDirLayout
            solverPlan
            localPackages
            sourcePackageHashes
            defaultInstallDirs
            projectConfigAllPackages
            projectConfigLocalPackages
            projectConfigSpecificPackage
      where
        mkTransport        = configureTransport verbosity preferredTransport
        preferredTransport = flagToMaybe (projectConfigHttpTransport
                                              projectConfigBuildOnly)


    -- Improve the elaborated install plan. The elaborated plan consists
    -- mostly of source packages (with full nix-style hashed ids). Where
    -- corresponding installed packages already exist in the store, replace
    -- them in the plan.
    --
    -- Note that we do monitor the store's package db here, so we will redo
    -- this improvement phase when the db changes -- including as a result of
    -- executing a plan and installing things.
    --
    phaseImprovePlan :: ElaboratedInstallPlan
                     -> ElaboratedSharedConfig
                     -> Rebuild ElaboratedInstallPlan
    phaseImprovePlan elaboratedPlan elaboratedShared = do

        liftIO $ debug verbosity "Improving the install plan..."
        recreateDirectory verbosity True storeDirectory
        storePkgIndex <- getPackageDBContents verbosity
                                              compiler progdb platform
                                              storePackageDb
        let improvedPlan = improveInstallPlanWithPreExistingPackages
                             storePkgIndex
                             elaboratedPlan
        return improvedPlan

      where
        storeDirectory  = cabalStoreDirectory (compilerId compiler)
        storePackageDb  = cabalStorePackageDB (compilerId compiler)
        ElaboratedSharedConfig {
          pkgConfigCompiler  = compiler,
          pkgConfigPlatform  = platform,
          pkgConfigProgramDb = progdb
        } = elaboratedShared



findProjectCabalFiles :: ProjectConfig -> Rebuild [FilePath]
findProjectCabalFiles ProjectConfig{..} = do
    monitorFiles (map MonitorFileGlob projectConfigPackageGlobs)
    liftIO $ map (projectConfigRootDir </>) . concat
         <$> mapM (matchFileGlob projectConfigRootDir) projectConfigPackageGlobs

readSourcePackage :: Verbosity -> FilePath -> Rebuild (PackageSpecifier SourcePackage)
readSourcePackage verbosity cabalFile = do
    -- no need to monitorFiles because findProjectCabalFiles did it already
    pkgdesc <- liftIO $ Cabal.readPackageDescription verbosity cabalFile
    let srcLocation = LocalUnpackedPackage (takeDirectory cabalFile)
    return $ SpecificSourcePackage 
               SourcePackage {
                 packageInfoId        = packageId pkgdesc,
                 packageDescription   = pkgdesc,
                 packageSource        = srcLocation,
                 packageDescrOverride = Nothing
               }

programsMonitorFiles :: ProgramDb -> [MonitorFilePath]
programsMonitorFiles progdb =
    [ monitor
    | prog    <- configuredPrograms progdb
    , monitor <- monitorFileSearchPath (programMonitorFiles prog)
                                       (programPath prog)
    ]

-- | Select the bits of a 'ProgramDb' to monitor for value changes.
-- Use 'programsMonitorFiles' for the files to monitor.
--
programsDbSignature :: ProgramDb -> [ConfiguredProgram]
programsDbSignature progdb =
    [ prog { programMonitorFiles = []
           , programOverrideEnv  = filter ((/="PATH") . fst)
                                          (programOverrideEnv prog) }
    | prog <- configuredPrograms progdb ]

getInstalledPackages :: Verbosity
                     -> Compiler -> ProgramDb -> Platform
                     -> PackageDBStack 
                     -> Rebuild InstalledPackageIndex
getInstalledPackages verbosity compiler progdb platform packagedbs = do
    monitorFiles . map MonitorFile
      =<< liftIO (IndexUtils.getInstalledPackagesMonitorFiles
                    verbosity compiler
                    packagedbs progdb platform)
    liftIO $ IndexUtils.getInstalledPackages
               verbosity compiler
               packagedbs progdb

getPackageDBContents :: Verbosity
                     -> Compiler -> ProgramDb -> Platform
                     -> PackageDB
                     -> Rebuild InstalledPackageIndex
getPackageDBContents verbosity compiler progdb platform packagedb = do
    monitorFiles . map MonitorFile
      =<< liftIO (IndexUtils.getInstalledPackagesMonitorFiles
                    verbosity compiler
                    [packagedb] progdb platform)
    liftIO $ do
      createPackageDBIfMissing verbosity compiler
                               progdb [packagedb]
      Cabal.getPackageDBContents verbosity compiler
                                 packagedb progdb

getSourcePackages :: Verbosity -> [Repo] -> Rebuild SourcePackageDb
getSourcePackages verbosity repos = do
    monitorFiles . map MonitorFile
                 $ IndexUtils.getSourcePackagesMonitorFiles repos
    liftIO $ IndexUtils.getSourcePackages verbosity repos


createPackageDBIfMissing :: Verbosity -> Compiler -> ProgramDb
                         -> PackageDBStack -> IO ()
createPackageDBIfMissing verbosity compiler progdb packageDbs =
  case reverse packageDbs of
    SpecificPackageDB dbPath : _ -> do
      exists <- liftIO $ Cabal.doesPackageDBExist dbPath
      unless exists $ do
        createDirectoryIfMissingVerbose verbosity False (takeDirectory dbPath)
        Cabal.createPackageDB verbosity compiler progdb False dbPath
    _ -> return ()


recreateDirectory :: Verbosity -> Bool -> FilePath -> Rebuild ()
recreateDirectory verbosity createParents dir = do
    liftIO $ createDirectoryIfMissingVerbose verbosity createParents dir
    monitorFiles [MonitorFile dir]


-- | Get the 'HashValue' for all the source packages where we use hashes,
-- and download any packages required to do so.
--
-- Note that we don't get hashes for local unpacked packages.
--
getPackageSourceHashes :: Verbosity
                       -> IO HttpTransport
                       -> SolverInstallPlan
                       -> Rebuild (Map PackageId PackageSourceHash)
getPackageSourceHashes verbosity mkTransport installPlan = do

    -- Determine which packages need fetching, and which are present already
    --
    pkgslocs <- liftIO $ sequence
      [ do let locm = packageSource pkg
           mloc <- checkFetched locm
           return (pkg, locm, mloc)
      | InstallPlan.Configured
          (ConfiguredPackage pkg _ _ _ _) <- InstallPlan.toList installPlan ]

    let requireDownloading = [ (pkg, locm) | (pkg, locm, Nothing) <- pkgslocs ]
        alreadyDownloaded  = [ (pkg, loc)  | (pkg, _, Just loc)   <- pkgslocs ]

    -- Download the ones we need
    --
    newlyDownloaded <-
      if null requireDownloading
        then return []
        else liftIO $ do
                transport <- mkTransport
                sequence
                  [ do loc <- fetchPackage transport verbosity locm
                       return (pkg, loc)
                  | (pkg, locm) <- requireDownloading ]

    -- Get the hashes of all the tarball packages (i.e. not local dir pkgs)
    --
    let pkgsTarballs =
          [ (packageId pkg, tarball)
          | (pkg, srcloc) <- newlyDownloaded ++ alreadyDownloaded
          , tarball <- maybeToList (tarballFileLocation srcloc) ]

    monitorFiles [ MonitorFile tarball | (_pkgid, tarball) <- pkgsTarballs ]

    liftM Map.fromList $ liftIO $
      sequence
        [ do srchash <- readFileHashValue tarball
             return (pkgid, srchash)
        | (pkgid, tarball) <- pkgsTarballs ]
  where
    tarballFileLocation (LocalUnpackedPackage _dir)      = Nothing
    tarballFileLocation (LocalTarballPackage    tarball) = Just tarball
    tarballFileLocation (RemoteTarballPackage _ tarball) = Just tarball
    tarballFileLocation (RepoTarballPackage _ _ tarball) = Just tarball


-- ------------------------------------------------------------
-- * Installation planning
-- ------------------------------------------------------------

planPackages :: Compiler
             -> Platform
             -> Solver -> ProjectConfigSolver
             -> InstalledPackageIndex
             -> SourcePackageDb
             -> [PackageSpecifier SourcePackage]
             -> Progress String String InstallPlan
planPackages comp platform solver solverconfig
             installedPkgIndex sourcePkgDb pkgSpecifiers =

    resolveDependencies
      platform (compilerInfo comp)
      solver
      resolverParams

  where

    resolverParams =

        setMaxBackjumps (if maxBackjumps < 0 then Nothing
                                             else Just maxBackjumps)

      . setIndependentGoals independentGoals

      . setReorderGoals reorderGoals

      . setAvoidReinstalls avoidReinstalls --TODO: [required eventually] should only be configurable for custom installs

      . setShadowPkgs shadowPkgs --TODO: [required eventually] should only be configurable for custom installs

      . setStrongFlags strongFlags

      . setPreferenceDefault (if upgradeDeps then PreferAllLatest
                                             else PreferLatestForSelected)
                             --TODO: [required eventually] decide if we need to prefer installed for global packages?

      . removeUpperBounds allowNewer

      . addDefaultSetupDepends (defaultSetupDeps platform
                              . PD.packageDescription . packageDescription)

      . addPreferences
          -- preferences from the config file or command line
          [ PackageVersionPreference name ver
          | Dependency name ver <- projectConfigSolverPreferences ]

      . addConstraints
          -- version constraints from the config file or command line
            [ LabeledPackageConstraint (userToPackageConstraint pc) src
            | (pc, src) <- projectConfigSolverConstraints ]

      . addConstraints
          [ let pc = PackageConstraintStanzas
                     (pkgSpecifierTarget pkgSpecifier) stanzas
            in LabeledPackageConstraint pc ConstraintSourceConfigFlagOrTarget
          | pkgSpecifier <- pkgSpecifiers ]

      . addConstraints
          --TODO: [nice to have] this just applies all flags to all targets which
          -- is silly. We should check if the flags are appropriate
          [ let pc = PackageConstraintFlags
                     (pkgSpecifierTarget pkgSpecifier) flags
            in LabeledPackageConstraint pc ConstraintSourceConfigFlagOrTarget
          | let flags = projectConfigConfigurationsFlags
          , not (null flags)
          , pkgSpecifier <- pkgSpecifiers ]

      . reinstallTargets  --TODO: [required eventually] do we want this? we already hide all installed packages in the store from the solver

      $ standardInstallPolicy
        installedPkgIndex sourcePkgDb pkgSpecifiers

    stanzas = [] --TODO: [required feature] should enable for local only [TestStanzas, BenchStanzas]
    --TODO: [required feature] while for the local mode we want to run the solver with the tests
    -- and benchmarks turned on by default (so the solution is stable when we
    -- actually enable/disable tests), but really we want to have a solver
    -- mode where it tries to enable these but if it can't work then to turn
    -- them off.
{-
      concat
        [ if testsEnabled then [TestStanzas] else []
        , if benchmarksEnabled then [BenchStanzas] else []
        ]
    testsEnabled = fromFlagOrDefault False $ configTests configFlags
    benchmarksEnabled = fromFlagOrDefault False $ configBenchmarks configFlags
-}
--    reinstall        = fromFlag projectConfigSolverReinstall
    reorderGoals     = fromFlag projectConfigSolverReorderGoals
    independentGoals = fromFlag projectConfigSolverIndependentGoals
    avoidReinstalls  = fromFlag projectConfigSolverAvoidReinstalls
    shadowPkgs       = fromFlag projectConfigSolverShadowPkgs
    strongFlags      = fromFlag projectConfigSolverStrongFlags
    maxBackjumps     = fromFlag projectConfigSolverMaxBackjumps
    upgradeDeps      = fromFlag projectConfigSolverUpgradeDeps
    allowNewer       = fromFlag projectConfigSolverAllowNewer

    ProjectConfigSolver{
      projectConfigSolverConstraints,
      projectConfigSolverPreferences,
      projectConfigConfigurationsFlags,

--      projectConfigSolverReinstall,  --TODO: [required eventually] check not configurable for local mode?
      projectConfigSolverReorderGoals,
      projectConfigSolverIndependentGoals,
      projectConfigSolverAvoidReinstalls,
      projectConfigSolverShadowPkgs,
      projectConfigSolverStrongFlags,
      projectConfigSolverMaxBackjumps,
      projectConfigSolverUpgradeDeps,
      projectConfigSolverAllowNewer
    } = solverconfig

------------------------------------------------------------------------------
-- * Install plan post-processing
------------------------------------------------------------------------------

-- This phase goes from the InstallPlan we get from the solver and has to
-- make an elaborated install plan.
--
-- We go in two steps:
--
--  1. elaborate all the source packages that the solver has chosen.
--  2. swap source packages for pre-existing installed packages wherever
--     possible.
--
-- We do it in this order, elaborating and then replacing, because the easiest
-- way to calculate the installed package ids used for the replacement step is
-- from the elaborated configuration for each package.




------------------------------------------------------------------------------
-- * Install plan elaboration
------------------------------------------------------------------------------

-- | Produce an elaborated install plan using the policy for local builds with
-- a nix-style shared store.
--
-- In theory should be able to make an elaborated install plan with a policy
-- matching that of the classic @cabal install --user@ or @--global@
--
elaborateInstallPlan
  :: Platform -> Compiler -> ProgramDb
  -> DistDirLayout
  -> CabalDirLayout
  -> SolverInstallPlan
  -> [PackageSpecifier SourcePackage]
  -> Map PackageId PackageSourceHash
  -> InstallDirs.InstallDirTemplates
  -> PackageConfigShared
  -> PackageConfig
  -> Map PackageName PackageConfig
  -> (ElaboratedInstallPlan, ElaboratedSharedConfig)
elaborateInstallPlan platform compiler progdb
                     DistDirLayout{..}
                     cabalDirLayout@CabalDirLayout{cabalStorePackageDB}
                     solverPlan pkgSpecifiers
                     sourcePackageHashes
                     defaultInstallDirs
                     sharedPackageConfig
                     localPackagesConfig
                     perPackageConfig =
    (elaboratedInstallPlan, elaboratedSharedConfig)
  where
    elaboratedSharedConfig =
      ElaboratedSharedConfig {
        pkgConfigPlatform         = platform,
        pkgConfigCompiler         = compiler,
        pkgConfigProgramDb        = progdb
      }

    elaboratedInstallPlan =
      flip InstallPlan.mapPreservingGraph solverPlan $ \mapDep planpkg ->
        case planpkg of
          InstallPlan.PreExisting pkg ->
            InstallPlan.PreExisting pkg

          InstallPlan.Configured  pkg ->
            InstallPlan.Configured
              (elaborateConfiguredPackage (fixupDependencies mapDep pkg))

          _ -> error "elaborateInstallPlan: unexpected package state"

    -- remap the installed package ids of the direct deps, since we're
    -- changing the installed package ids of all the packages to use the
    -- final nix-style hashed ids.
    fixupDependencies mapDep
       (ConfiguredPackage pkg flags stanzas deps  setup) =
        ConfiguredPackage pkg flags stanzas deps' setup
      where
        deps' = fmap (map (\d -> d { confInstId = mapDep (confInstId d) })) deps

    elaborateConfiguredPackage :: ConfiguredPackage
                               -> ElaboratedConfiguredPackage
    elaborateConfiguredPackage
        pkg@(ConfiguredPackage (SourcePackage pkgid gdesc srcloc descOverride)
                               flags stanzas deps _) =
        elaboratedPackage
      where
        -- Knot tying: the final elaboratedPackage includes the
        -- pkgInstalledId, which is calculated by hashing many
        -- of the other fields of the elaboratedPackage.
        --
        elaboratedPackage = ElaboratedConfiguredPackage {..}

        pkgInstalledId
          | shouldBuildInplaceOnly pkg
          = InstalledPackageId (display pkgid ++ "-inplace")
          
          | otherwise
          = assert (isJust pkgSourceHash) $
            hashedInstalledPackageId
              (packageHashInputs
                elaboratedSharedConfig
                elaboratedPackage)  -- recursive use of elaboratedPackage

          | otherwise
          = error $ "elaborateInstallPlan: non-inplace package "
                 ++ " is missing a source hash: " ++ display pkgid

        -- All the other fields of the ElaboratedConfiguredPackage
        --
        pkgSourceId         = pkgid
        pkgDescription      = gdesc
        pkgFlagAssignment   = flags
        pkgEnabledStanzas   = stanzas
        pkgTestsuitesEnable = TestStanzas  `elem` stanzas --TODO: [required feature] only actually enable if solver allows it and we want it
        pkgBenchmarksEnable = BenchStanzas `elem` stanzas --TODO: [required feature] only actually enable if solver allows it and we want it
        pkgDependencies     = deps
        pkgSourceLocation   = srcloc
        pkgSourceHash       = Map.lookup pkgid sourcePackageHashes
        pkgBuildStyle       = if shouldBuildInplaceOnly pkg
                                then BuildInplaceOnly else BuildAndInstall
        pkgBuildPackageDBStack    = buildAndRegisterDbs
        pkgRegisterPackageDBStack = buildAndRegisterDbs
        pkgRequiresRegistration   = isJust (Cabal.condLibrary gdesc)

        pkgSetupScriptStyle       = packageSetupScriptStyle desc
        pkgSetupScriptCliVersion  = packageSetupScriptSpecVersion desc deps
        pkgSetupPackageDBStack    = buildAndRegisterDbs        
        desc                      = Cabal.packageDescription gdesc

        pkgDescriptionOverride    = descOverride

        pkgVanillaLib    = sharedOptionFlag True  packageConfigVanillaLib --TODO: [required feature]: also needs to be handled recursively
        pkgSharedLib     = pkgid `Set.member` pkgsUseSharedLibrary
        pkgDynExe        = perPkgOptionFlag pkgid False packageConfigDynExe
        pkgGHCiLib       = perPkgOptionFlag pkgid False packageConfigGHCiLib --TODO: [required feature] needs to default to enabled on windows still

        pkgProfExe       = perPkgOptionFlag pkgid False packageConfigProf
        pkgProfLib       = pkgid `Set.member` pkgsUseProfilingLibrary

        (pkgProfExeDetail,
         pkgProfLibDetail) = perPkgOptionLibExeFlag pkgid ProfDetailDefault
                               packageConfigProfDetail
                               packageConfigProfLibDetail
        pkgCoverage      = perPkgOptionFlag pkgid False packageConfigCoverage

        pkgOptimization  = perPkgOptionFlag pkgid NormalOptimisation packageConfigOptimization
        pkgSplitObjs     = perPkgOptionFlag pkgid False packageConfigSplitObjs
        pkgStripLibs     = perPkgOptionFlag pkgid False packageConfigStripLibs
        pkgStripExes     = perPkgOptionFlag pkgid False packageConfigStripExes
        pkgDebugInfo     = perPkgOptionFlag pkgid NoDebugInfo packageConfigDebugInfo

        pkgConfigureScriptArgs = perPkgOptionList pkgid packageConfigConfigureArgs
        pkgExtraLibDirs        = perPkgOptionList pkgid packageConfigExtraLibDirs
        pkgExtraIncludeDirs    = perPkgOptionList pkgid packageConfigExtraIncludeDirs
        pkgProgPrefix          = perPkgOptionMaybe pkgid packageConfigProgPrefix
        pkgProgSuffix          = perPkgOptionMaybe pkgid packageConfigProgSuffix
        pkgBuildTargets        = Nothing -- sometimes gets adjusted later

        pkgInstallDirs
          | shouldBuildInplaceOnly pkg
          -- use the ordinary default install dirs
          = (InstallDirs.absoluteInstallDirs
               pkgid
               (LibraryName (display pkgid))
               (compilerInfo compiler)
               InstallDirs.NoCopyDest
               platform
               defaultInstallDirs) {

              InstallDirs.libsubdir  = "", -- absoluteInstallDirs sets these as
              InstallDirs.datasubdir = ""  -- 'undefined' but we have to use
            }                              -- them as "Setup.hs configure" args

          | otherwise
          -- use special simplified install dirs
          = storePackageInstallDirs
              cabalDirLayout
              (compilerId compiler)
              pkgInstalledId

        buildAndRegisterDbs
          | shouldBuildInplaceOnly pkg = inplacePackageDbs
          | otherwise                  = storePackageDbs

    sharedOptionFlag  :: a         -> (PackageConfigShared -> Flag a) -> a
    perPkgOptionFlag  :: PackageId -> a ->  (PackageConfig -> Flag a) -> a
    perPkgOptionMaybe :: PackageId ->       (PackageConfig -> Flag a) -> Maybe a
    perPkgOptionList  :: PackageId ->       (PackageConfig -> [a])    -> [a]

    sharedOptionFlag def f = fromFlagOrDefault def shared
      where
        shared = f sharedPackageConfig

    perPkgOptionFlag  pkgid def f = fromFlagOrDefault def (lookupPerPkgOption pkgid f)
    perPkgOptionMaybe pkgid     f = flagToMaybe (lookupPerPkgOption pkgid f)
    perPkgOptionList  pkgid     f = lookupPerPkgOption pkgid f

    perPkgOptionLibExeFlag pkgid def fboth flib = (exe, lib)
      where
        exe = fromFlagOrDefault def bothflag
        lib = fromFlagOrDefault def (bothflag <> libflag)

        bothflag = lookupPerPkgOption pkgid fboth
        libflag  = lookupPerPkgOption pkgid flib

    lookupPerPkgOption :: (Package pkg, Monoid m)
                       => pkg -> (PackageConfig -> m) -> m
    lookupPerPkgOption pkg f
      -- the project config specifies values that apply to packages local to
      -- but by default non-local packages get all default config values
      -- the project, and can specify per-package values for any package,
      | isLocalToProject pkg = local <> perpkg
      | otherwise            =          perpkg
      where
        local  = f localPackagesConfig
        perpkg = maybe mempty f (Map.lookup (packageName pkg) perPackageConfig)

    inplacePackageDbs = storePackageDbs
                     ++ [ distPackageDB (compilerId compiler) ]

    storePackageDbs   = [ GlobalPackageDB
                        , cabalStorePackageDB (compilerId compiler) ]

    -- For this local build policy, every package that lives in a local source
    -- dir (as opposed to a tarball), or depends on such a package, will be
    -- built inplace into a shared dist dir. Tarball packages that depend on
    -- source dir packages will also get unpacked locally.
    shouldBuildInplaceOnly :: HasInstalledPackageId pkg => pkg -> Bool
    shouldBuildInplaceOnly pkg = Set.member (installedPackageId pkg)
                                            pkgsToBuildInplaceOnly

    pkgsToBuildInplaceOnly :: Set InstalledPackageId
    pkgsToBuildInplaceOnly =
        Set.fromList
      $ map installedPackageId
      $ InstallPlan.reverseDependencyClosure
          solverPlan
          [ fakeInstalledPackageId (packageId pkg)
          | SpecificSourcePackage pkg <- pkgSpecifiers ]

    isLocalToProject :: Package pkg => pkg -> Bool
    isLocalToProject pkg = Set.member (packageId pkg)
                                      pkgsLocalToProject

    pkgsLocalToProject :: Set PackageId
    pkgsLocalToProject =
      Set.fromList
        [ packageId pkg
        | SpecificSourcePackage pkg <- pkgSpecifiers ]

    pkgsUseSharedLibrary :: Set PackageId
    pkgsUseSharedLibrary =
        packagesWithDownwardClosedProperty needsSharedLib
      where
        needsSharedLib pkg =
            fromMaybe compilerShouldUseSharedLibByDefault
                      (liftM2 (||) pkgSharedLib pkgDynExe)
          where
            pkgid        = packageId pkg
            pkgSharedLib = flagToMaybe (packageConfigSharedLib sharedPackageConfig)
            pkgDynExe    = perPkgOptionMaybe pkgid packageConfigDynExe

    --TODO: [code cleanup] move this into the Cabal lib. It's currently open
    -- coded in Distribution.Simple.Configure, but should be made a proper
    -- function of the Compiler or CompilerInfo.
    compilerShouldUseSharedLibByDefault =
      case compilerFlavor compiler of
        GHC   -> GHC.isDynamic compiler
        GHCJS -> GHCJS.isDynamic compiler
        _     -> False

    pkgsUseProfilingLibrary :: Set PackageId
    pkgsUseProfilingLibrary =
        packagesWithDownwardClosedProperty needsProfilingLib
      where
        needsProfilingLib pkg =
            fromFlagOrDefault False (profBothFlag <> profLibFlag)
          where
            pkgid        = packageId pkg
            profBothFlag = lookupPerPkgOption pkgid packageConfigProf
            profLibFlag  = lookupPerPkgOption pkgid packageConfigProfLib
            --TODO: [code cleanup] unused: the old deprecated packageConfigProfExe

    packagesWithDownwardClosedProperty property =
        Set.fromList
      $ map packageId
      $ InstallPlan.dependencyClosure
          solverPlan
          [ installedPackageId pkg
          | pkg <- InstallPlan.toList solverPlan
          , property pkg ] -- just the packages that satisfy the propety
      --TODO: [nice to have] this does not check the config consistency,
      -- e.g. a package explicitly turning off profiling, but something
      -- depending on it that needs profiling. This really needs a separate
      -- package config validation/resolution pass.

      --TODO: [nice to have] config consistency checking:
      -- * profiling libs & exes, exe needs lib, recursive
      -- * shared libs & exes, exe needs lib, recursive
      -- * vanilla libs & exes, exe needs lib, recursive
      -- * ghci or shared lib needed by TH, recursive, ghc version dependent


---------------------------
-- Setup.hs script policy
--

-- Handling for Setup.hs scripts is a bit tricky, part of it lives in the
-- solver phase, and part in the elaboration phase. We keep the helper
-- functions for both phases together here so at least you can see all of it
-- in one place.

-- | There are four major cases for Setup.hs handling:
--
--  1. @build-type@ Custom with a @custom-setup@ section
--  2. @build-type@ Custom without a @custom-setup@ section
--  3. @build-type@ not Custom with @cabal-version >  $our-cabal-version@
--  4. @build-type@ not Custom with @cabal-version <= $our-cabal-version@
--
-- It's also worth noting that packages specifying @cabal-version: >= 1.23@
-- or later that have @build-type@ Custom will always have a @custom-setup@
-- section. Therefore in case 2, the specified @cabal-version@ will always be
-- less than 1.23.
--
-- In cases 1 and 2 we obviously have to build an external Setup.hs script,
-- while in case 4 we can use the internal library API. In case 3 we also have
-- to build an external Setup.hs script because the package needs a later
-- Cabal lib version than we can support internally.
--
data SetupScriptStyle = SetupCustomExplicitDeps
                      | SetupCustomImplicitDeps
                      | SetupNonCustomExternalLib
                      | SetupNonCustomInternalLib
  deriving (Eq, Show, Generic)

instance Binary SetupScriptStyle


packageSetupScriptStyle :: PD.PackageDescription -> SetupScriptStyle
packageSetupScriptStyle pkg
  | buildType == PD.Custom
  , isJust (PD.setupBuildInfo pkg)
  = SetupCustomExplicitDeps

  | buildType == PD.Custom
  = SetupCustomImplicitDeps

  | PD.specVersion pkg > cabalVersion -- one cabal-install is built against
  = SetupNonCustomExternalLib

  | otherwise
  = SetupNonCustomInternalLib
  where
    buildType = fromMaybe Cabal.Custom (Cabal.buildType pkg)


-- | Part of our Setup.hs handling policy is implemented by getting the solver
-- to work out setup dependencies for packages. The solver already handles
-- packages that explicitly specify setup dependencies, but we can also tell
-- the solver to treat other packages as if they had setup dependencies.
-- That's what this function does, it gets called by the solver for all
-- packages that don't already have setup dependencies.
--
-- The dependencies we want to add is different for each 'SetupScriptStyle'.
--
defaultSetupDeps :: Platform -> PD.PackageDescription -> [Dependency]
defaultSetupDeps platform pkg =
    case packageSetupScriptStyle pkg of

      -- For packages with build type custom that do not specify explicit
      -- setup dependencies, we add a dependency on Cabal and a number
      -- of other packages.
      SetupCustomImplicitDeps ->
        [ Dependency depPkgname anyVersion
        | depPkgname <- legacyCustomSetupPkgs platform ] ++
        -- The Cabal dep is slightly special:
        --  * we omit the dep for the Cabal lib itself (since it bootstraps),
        --  * we constrain it to be less than 1.23 since all packages
        --    relying on later Cabal spec versions are supposed to use
        --    explit setup deps. Having this constraint also allows later
        --    Cabal lib versions to make breaking API changes without breaking
        --    all old Setup.hs scripts.
        [ Dependency cabalPkgname cabalConstraint
        | packageName pkg /= cabalPkgname ]
        where
          cabalConstraint   = orLaterVersion (PD.specVersion pkg)
                                `intersectVersionRanges`
                              earlierVersion cabalCompatMaxVer
          cabalCompatMaxVer = Version [1,23] []
 
      -- For other build types (like Simple) if we still need to compile an
      -- external Setup.hs, it'll be one of the simple ones that only depends
      -- on Cabal and base.
      SetupNonCustomExternalLib ->
        [ Dependency cabalPkgname cabalConstraint
        , Dependency basePkgname  anyVersion ]
        where
          cabalConstraint = orLaterVersion (PD.specVersion pkg)
  
      -- The internal setup wrapper method has no deps at all.
      SetupNonCustomInternalLib -> []

      SetupCustomExplicitDeps ->
        error $ "defaultSetupDeps: called for a package with explicit "
             ++ "setup deps: " ++ display (packageId pkg)


-- | Work out which version of the Cabal spec we will be using to talk to the
-- Setup.hs interface for this package.
--
-- This depends somewhat on the 'SetupScriptStyle' but most cases are a result
-- of what the solver picked for us, based on the explicit setup deps or the
-- ones added implicitly by 'defaultSetupDeps'.
--
packageSetupScriptSpecVersion :: Package pkg
                              => PD.PackageDescription
                              -> ComponentDeps [pkg]
                              -> Version
packageSetupScriptSpecVersion pkg deps =
    case packageSetupScriptStyle pkg of

      -- We're going to be using the internal Cabal library, so the spec
      -- version of that is simply the version of the Cabal library that
      -- cabal-install has been built with.
      SetupNonCustomInternalLib ->
        cabalVersion

      -- If we happen to be building the Cabal lib itself then because that
      -- bootstraps itself then we use the version of the lib we're building.
      SetupCustomImplicitDeps | packageName pkg == cabalPkgname ->
        packageVersion pkg

      -- In all other cases we have a look at what version of the Cabal lib
      -- the solver picked. Or if it didn't depend on Cabal at all (which is
      -- very rare) then we look at the .cabal file to see what spec version
      -- it declares.
      _ -> case find ((cabalPkgname ==) . packageName) (CD.setupDeps deps) of 
             Just dep -> packageVersion dep
             Nothing  -> PD.specVersion pkg


cabalPkgname, basePkgname :: PackageName
cabalPkgname = PackageName "Cabal"
basePkgname  = PackageName "base"


legacyCustomSetupPkgs :: Platform -> [PackageName]
legacyCustomSetupPkgs (Platform _ os) =
    map PackageName $
        [ "array", "base", "binary", "bytestring", "containers"
        , "deepseq", "directory", "filepath", "pretty"
        , "process", "time" ]
     ++ [ "Win32" | os == Windows ]
     ++ [ "unix"  | os /= Windows ]

-- The other aspects of our Setup.hs policy lives here where we decide on
-- the 'SetupScriptOptions'.
--
-- Our current policy for the 'SetupCustomImplicitDeps' case is that we
-- try to make the implicit deps cover everything, and we don't allow the
-- compiler to pick up other deps. This may or may not be sustainable, and
-- we might have to allow the deps to be non-exclusive, but that itself would
-- be tricky since we would have to allow the Setup access to all the packages
-- in the store and local dbs.

setupHsScriptOptions :: ElaboratedReadyPackage
                     -> ElaboratedSharedConfig
                     -> FilePath
                     -> FilePath
                     -> Bool
                     -> Lock
                     -> SetupScriptOptions
setupHsScriptOptions (ReadyPackage ElaboratedConfiguredPackage{..} deps)
                     ElaboratedSharedConfig{..} srcdir builddir
                     isParallelBuild cacheLock =
    SetupScriptOptions {
      useCabalVersion          = thisVersion pkgSetupScriptCliVersion,
      useCabalSpecVersion      = Just pkgSetupScriptCliVersion,
      useCompiler              = Just pkgConfigCompiler,
      usePlatform              = Just pkgConfigPlatform,
      usePackageDB             = pkgSetupPackageDBStack,
      usePackageIndex          = Nothing,
      useDependencies          = [ (installedPackageId ipkg, packageId ipkg)
                                 | ipkg <- CD.setupDeps deps ],
      useDependenciesExclusive = True,
      useVersionMacros         = pkgSetupScriptStyle == SetupCustomExplicitDeps,
      useProgramConfig         = pkgConfigProgramDb,
      useDistPref              = builddir,
      useLoggingHandle         = Nothing, -- this gets set later
      useWorkingDir            = Just srcdir,
      useWin32CleanHack        = False,   --TODO: [required eventually]
      forceExternalSetupMethod = isParallelBuild,
      setupCacheLock           = Just cacheLock
    }


-- | To be used for the input for elaborateInstallPlan.
--
-- TODO: [code cleanup] make InstallDirs.defaultInstallDirs pure.
--
userInstallDirTemplates :: Compiler
                        -> IO InstallDirs.InstallDirTemplates
userInstallDirTemplates compiler = do
    InstallDirs.defaultInstallDirs
                  (compilerFlavor compiler)
                  True  -- user install
                  False -- unused

storePackageInstallDirs :: CabalDirLayout
                        -> CompilerId
                        -> InstalledPackageId
                        -> InstallDirs.InstallDirs FilePath
storePackageInstallDirs CabalDirLayout{cabalStorePackageDirectory}
                        compid ipkgid =
    InstallDirs.InstallDirs {..}
  where
    prefix       = cabalStorePackageDirectory compid ipkgid
    bindir       = prefix </> "bin"
    libdir       = prefix </> "lib"
    libsubdir    = ""
    dynlibdir    = libdir
    libexecdir   = prefix </> "libexec"
    includedir   = libdir </> "include"
    datadir      = prefix </> "share"
    datasubdir   = ""
    docdir       = datadir </> "doc"
    mandir       = datadir </> "man"
    htmldir      = docdir  </> "html"
    haddockdir   = htmldir
    sysconfdir   = prefix </> "etc"


--TODO: [code cleanup] perhaps reorder this code
-- based on the ElaboratedInstallPlan + ElaboratedSharedConfig,
-- make the various Setup.hs {configure,build,copy} flags


setupHsConfigureFlags :: ElaboratedReadyPackage
                      -> ElaboratedSharedConfig
                      -> Verbosity
                      -> FilePath
                      -> Cabal.ConfigFlags
setupHsConfigureFlags (ReadyPackage
                         ElaboratedConfiguredPackage{..}
                         pkgdeps)
                      ElaboratedSharedConfig{..}
                      verbosity builddir =
    Cabal.ConfigFlags {..}
  where
    configDistPref            = toFlag builddir
    configVerbosity           = toFlag verbosity

    configProgramPaths        = programDbProgramPaths pkgConfigProgramDb
    configProgramArgs         = programDbProgramArgs  pkgConfigProgramDb
    configProgramPathExtra    = programDbPathExtra    pkgConfigProgramDb
    configHcFlavor            = toFlag (compilerFlavor pkgConfigCompiler)
    configHcPath              = mempty -- use configProgramPaths instead
    configHcPkg               = mempty -- use configProgramPaths instead

    configVanillaLib          = toFlag pkgVanillaLib
    configSharedLib           = toFlag pkgSharedLib
    configDynExe              = toFlag pkgDynExe
    configGHCiLib             = toFlag pkgGHCiLib
    configProfExe             = mempty
    configProfLib             = toFlag pkgProfLib
    configProf                = toFlag pkgProfExe

    -- configProfDetail is for exe+lib, but overridden by configProfLibDetail
    -- so we specify both so we can specify independently
    configProfDetail          = toFlag pkgProfExeDetail
    configProfLibDetail       = toFlag pkgProfLibDetail

    configCoverage            = toFlag pkgCoverage
    configLibCoverage         = mempty

    configOptimization        = toFlag pkgOptimization
    configSplitObjs           = toFlag pkgSplitObjs
    configStripExes           = toFlag pkgStripExes
    configStripLibs           = toFlag pkgStripLibs
    configDebugInfo           = toFlag pkgDebugInfo

    configConfigurationsFlags = pkgFlagAssignment
    configConfigureArgs       = pkgConfigureScriptArgs
    configExtraLibDirs        = pkgExtraLibDirs
    configExtraIncludeDirs    = pkgExtraIncludeDirs
    configProgPrefix          = maybe mempty toFlag pkgProgPrefix
    configProgSuffix          = maybe mempty toFlag pkgProgSuffix

    configInstallDirs         = fmap (toFlag . InstallDirs.toPathTemplate)
                                     pkgInstallDirs

    -- we only use configDependencies, unless we're talking to an old Cabal
    -- in which case we use configConstraints
    configDependencies        = [ (packageName (Installed.sourcePackageId deppkg),
                                  Installed.installedPackageId deppkg)
                                | deppkg <- CD.nonSetupDeps pkgdeps ]
    configConstraints         = [ thisPackageVersion (packageId deppkg)
                                | deppkg <- CD.nonSetupDeps pkgdeps ]

    -- explicitly clear, then our package db stack
    -- TODO: [required eventually] have to do this differently for older Cabal versions
    configPackageDBs          = Nothing : map Just pkgBuildPackageDBStack

    configInstantiateWith     = mempty --TODO: [research required] unused within cabal-install
    configTests               = toFlag pkgTestsuitesEnable
    configBenchmarks          = toFlag pkgBenchmarksEnable

    configExactConfiguration  = toFlag True
    configFlagError           = mempty --TODO: [research required] appears not to be implemented
    configRelocatable         = mempty --TODO: [research required] ???
    configScratchDir          = mempty -- never use
    configUserInstall         = mempty -- don't rely on defaults
    configPrograms            = error "setupHsConfigureFlags: configPrograms"

    programDbProgramPaths db =
      [ (programId prog, programPath prog)
      | prog <- configuredPrograms db ]

    programDbProgramArgs db =
      [ (programId prog, programOverrideArgs prog)
      | prog <- configuredPrograms db ]

    programDbPathExtra db =
      case getProgramSearchPath db of
        ProgramSearchPathDefault : extra ->
          toNubList [ dir | ProgramSearchPathDir dir <- extra ]
        _ -> error $ "setupHsConfigureFlags: we cannot currently cope with a "
                  ++ "search path that does not start with the system path"
                  -- the Setup.hs interface only has --extra-prog-path
                  -- so we cannot put things before the $PATH, only after


setupHsBuildFlags :: ElaboratedConfiguredPackage
                  -> ElaboratedSharedConfig
                  -> Verbosity
                  -> FilePath
                  -> Cabal.BuildFlags
setupHsBuildFlags pkg@ElaboratedConfiguredPackage{..} _ verbosity builddir =
    Cabal.BuildFlags {
      buildProgramPaths = mempty, --unused, set at configure time
      buildProgramArgs  = mempty, --unused, set at configure time
      buildVerbosity    = toFlag verbosity,
      buildDistPref     = toFlag builddir,
      buildNumJobs      = mempty, --TODO: [nice to have] sometimes want to use toFlag (Just numBuildJobs),
      buildArgs         = maybe [] showBuildTargets pkgBuildTargets
    }
  where
    showBuildTargets = map (showBuildTarget QL3 (packageId pkg))
 

setupHsCopyFlags :: ElaboratedConfiguredPackage
                 -> ElaboratedSharedConfig
                 -> Verbosity
                 -> FilePath
                 -> Cabal.CopyFlags
setupHsCopyFlags _ _ verbosity builddir =
    Cabal.CopyFlags {
      --TODO: [nice to have] we currently just rely on Setup.hs copy to always do the right
      -- thing, but perhaps we ought really to copy into an image dir and do
      -- some sanity checks and move into the final location ourselves
      copyDest      = toFlag InstallDirs.NoCopyDest,
      copyDistPref  = toFlag builddir,
      copyVerbosity = toFlag verbosity
    }

setupHsRegisterFlags :: ElaboratedConfiguredPackage
                     -> ElaboratedSharedConfig
                     -> Verbosity
                     -> FilePath
                     -> FilePath
                     -> Cabal.RegisterFlags
setupHsRegisterFlags ElaboratedConfiguredPackage {pkgBuildStyle} _
                     verbosity builddir pkgConfFile =
    Cabal.RegisterFlags {
      regPackageDB   = mempty,  -- misfeature
      regGenScript   = mempty,  -- never use
      regGenPkgConf  = toFlag (Just pkgConfFile),
      regInPlace     = case pkgBuildStyle of
                         BuildInplaceOnly -> toFlag True
                         _                -> toFlag False,
      regPrintId     = mempty,  -- never use
      regDistPref    = toFlag builddir,
      regVerbosity   = toFlag verbosity
    }

{- TODO: [required feature]
setupHsHaddockFlags :: ElaboratedConfiguredPackage
                    -> ElaboratedSharedConfig
                    -> Verbosity
                    -> FilePath
                    -> Cabal.HaddockFlags
setupHsHaddockFlags _ _ verbosity builddir =
    Cabal.HaddockFlags {
    }

setupHsTestFlags :: ElaboratedConfiguredPackage
                 -> ElaboratedSharedConfig
                 -> Verbosity
                 -> FilePath
                 -> Cabal.TestFlags
setupHsTestFlags _ _ verbosity builddir =
    Cabal.TestFlags {
    }
-}

------------------------------------------------------------------------------
-- * Sharing installed packages
------------------------------------------------------------------------------

--
-- Nix style store management for tarball packages
--
-- So here's our strategy:
--
-- We use a per-user nix-style hashed store, but /only/ for tarball packages.
-- So that includes packages from hackage repos (and other http and local
-- tarballs). For packages in local directories we do not register them into
-- the shared store by default, we just build them locally inplace.
--
-- The reason we do it like this is that it's easy to make stable hashes for
-- tarball packages, and these packages benefit most from sharing. By contrast
-- unpacked dir packages are harder to hash and they tend to change more
-- frequently so there's less benefit to sharing them.
--
-- When using the nix store approach we have to run the solver *without*
-- looking at the packages installed in the store, just at the source packages
-- (plus core\/global installed packages). Then we do a post-processing pass
-- to replace configured packages in the plan with pre-existing ones, where
-- possible. Where possible of course means where the nix-style package hash
-- equals one that's already in the store.
--
-- One extra wrinkle is that unless we know package tarball hashes upfront, we
-- will have to download the tarballs to find their hashes. So we have two
-- options: delay replacing source with pre-existing installed packages until
-- the point during the execution of the install plan where we have the
-- tarball, or try to do as much up-front as possible and then check again
-- during plan execution. The former isn't great because we would end up
-- telling users we're going to re-install loads of packages when in fact we
-- would just share them. It'd be better to give as accurate a prediction as
-- we can. The latter is better for users, but we do still have to check
-- during plan execution because it's important that we don't replace existing
-- installed packages even if they have the same package hash, because we
-- don't guarantee ABI stability.

-- TODO: [required eventually] for safety of concurrent installs, we must make sure we register but
-- not replace installed packages with ghc-pkg.

packageHashInputs :: ElaboratedSharedConfig
                  -> ElaboratedConfiguredPackage
                  -> PackageHashInputs
packageHashInputs
    pkgshared
    pkg@ElaboratedConfiguredPackage{
      pkgSourceId,
      pkgSourceHash = Just srchash,
      pkgDependencies
    } =
    PackageHashInputs {
      pkgHashPkgId       = pkgSourceId,
      pkgHashSourceHash  = srchash,
      -- Yes, we use all the deps here (lib, exe and setup)
      pkgHashDirectDeps  = map installedPackageId (CD.flatDeps pkgDependencies),
      pkgHashOtherConfig = packageHashConfigInputs pkgshared pkg
    }
packageHashInputs _ _ =
    error "packageHashInputs: only for packages with source hashes"

packageHashConfigInputs :: ElaboratedSharedConfig
                        -> ElaboratedConfiguredPackage
                        -> PackageHashConfigInputs
packageHashConfigInputs
    ElaboratedSharedConfig{..}
    ElaboratedConfiguredPackage{..} =

    PackageHashConfigInputs {
      pkgHashCompilerId          = compilerId pkgConfigCompiler,
      pkgHashPlatform            = pkgConfigPlatform,
      pkgHashFlagAssignment      = pkgFlagAssignment,
      pkgHashConfigureScriptArgs = pkgConfigureScriptArgs,
      pkgHashVanillaLib          = pkgVanillaLib,
      pkgHashSharedLib           = pkgSharedLib,
      pkgHashDynExe              = pkgDynExe,
      pkgHashGHCiLib             = pkgGHCiLib,
      pkgHashProfLib             = pkgProfLib,
      pkgHashProfExe             = pkgProfExe,
      pkgHashProfLibDetail       = pkgProfLibDetail,
      pkgHashProfExeDetail       = pkgProfExeDetail,
      pkgHashCoverage            = pkgCoverage,
      pkgHashOptimization        = pkgOptimization,
      pkgHashSplitObjs           = pkgSplitObjs,
      pkgHashStripLibs           = pkgStripLibs,
      pkgHashStripExes           = pkgStripExes,
      pkgHashDebugInfo           = pkgDebugInfo,
      pkgHashExtraLibDirs        = pkgExtraLibDirs,
      pkgHashExtraIncludeDirs    = pkgExtraIncludeDirs,
      pkgHashProgPrefix          = pkgProgPrefix,
      pkgHashProgSuffix          = pkgProgSuffix
    }


-- | Given the 'InstalledPackageIndex' for a nix-style package store, and
-- enough information to calculate 'InstalledPackageId' for a selection of
-- source packages 
-- 
improveInstallPlanWithPreExistingPackages
  :: forall srcpkg iresult ifailure.
     (HasInstalledPackageId srcpkg, PackageFixedDeps srcpkg)
  => InstalledPackageIndex
  -> GenericInstallPlan InstalledPackageInfo srcpkg iresult ifailure
  -> GenericInstallPlan InstalledPackageInfo srcpkg iresult ifailure
improveInstallPlanWithPreExistingPackages installedPkgIndex =

    go []
  where
    -- So here's the strategy:
    --
    --  * Go through each ready package in dependency order. Indeed we
    --    simulate executing the plan, but instead of going from ready to
    --    processing to installed, we go from ready to either pre-existing
    --    or processing.
    --
    --  * Calculate the 'InstalledPackageId' if we can (ie if we've been able
    --    to get the tarball hash)
    --
    --  * Check if that package is already installed and if so, we replace the
    --    ready pacage by the pre-existing package.
    --
    --  * If we cannot calculate the 'InstalledPackageId' or it's not already
    --    installed (ie we would have to build it) then we put it into the
    --    'Processing' state so that it doesn't keep appearing in the ready
    --    list.
    --
    --  * When there are no more packages in the ready state then we're done,
    --    except that we need to reset the packages we put into the processing
    --    state.
    --
    -- When we have ready packages that we cannot replace with pre-existing
    -- packages then none of their dependencies can be replaced either. This
    -- constraint is respected here because we put those packages into the
    -- processing state, and so none of their deps will be able to appear in
    -- the ready list.
    --
    -- We accumulate the packages in the processing state. These are the ones
    -- that will have to be built because they cannot be replaced with
    -- pre-existing installed packages.

    go :: [GenericReadyPackage srcpkg InstalledPackageInfo]
       -> GenericInstallPlan InstalledPackageInfo srcpkg iresult ifailure
       -> GenericInstallPlan InstalledPackageInfo srcpkg iresult ifailure
    go cannotBeImproved installPlan =
      case InstallPlan.ready installPlan of
        -- no more source packages can be replaced with pre-existing ones,
        --  just need to reset the ones we put into the processing state
        [] -> InstallPlan.reverted
                [ pkg | ReadyPackage pkg _ <- cannotBeImproved ]
                installPlan

        -- we have some to look at
        pkgs -> go (cannotBeImproved' ++ cannotBeImproved)
                   installPlan'
          where
            installPlan' = InstallPlan.processing cannotBeImproved'
                         . replaceWithPreExisting canBeImproved
                         $ installPlan

            (cannotBeImproved', canBeImproved) =
              partitionEithers
                [ case canPackageBeImproved pkg of
                    Nothing   -> Left pkg
                    Just ipkg -> Right (pkg, ipkg)
                | (pkg, _) <- pkgs ]

    canPackageBeImproved :: GenericReadyPackage srcpkg InstalledPackageInfo
                         -> Maybe InstalledPackageInfo
    canPackageBeImproved pkg = PackageIndex.lookupInstalledPackageId
                                 installedPkgIndex (installedPackageId pkg)

    replaceWithPreExisting :: [(GenericReadyPackage srcpkg InstalledPackageInfo, InstalledPackageInfo)]
                           -> GenericInstallPlan InstalledPackageInfo srcpkg iresult ifailure
                           -> GenericInstallPlan InstalledPackageInfo srcpkg iresult ifailure
    replaceWithPreExisting canBeImproved plan0 =
      foldl' (\plan (pkg, ipkg) -> InstallPlan.preexisting (installedPackageId pkg) ipkg plan)
             plan0
             canBeImproved
