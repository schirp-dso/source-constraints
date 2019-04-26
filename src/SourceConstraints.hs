{-# LANGUAGE RankNTypes #-}

module SourceConstraints (plugin, warnings) where

import Bag (emptyBag, unitBag, unionManyBags)
import Control.Applicative (Alternative(empty), Applicative(pure))
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Bool (Bool(False), not)
import Data.Char (isUpper)
import Data.Data (Data, Typeable, cast, gmapQ)
import Data.Eq (Eq((/=)))
import Data.Foldable (Foldable(elem), find)
import Data.Function (($), (.), on)
import Data.Functor ((<$>))
import Data.Generics.Aliases (ext2Q, extQ, mkQ)
import Data.Generics.Text (gshow)
import Data.List (intercalate, sort, sortBy, zip3)
import Data.Maybe (Maybe(Nothing), fromJust, maybe)
import Data.Ord (Ord(compare))
import Data.Semigroup ((<>))
import Data.String (String)
import DynFlags (DynFlags, getDynFlags)
import ErrUtils (ErrMsg, WarningMessages, mkWarnMsg)
import HsDecls
  ( HsDerivingClause
    ( HsDerivingClause
    , deriv_clause_strategy
    )
  , LHsDerivingClause
  )
import HsExtension (GhcPs)
import HsSyn
  ( IE
    ( IEModuleContents
    , IEThingAbs
    , IEThingAll
    , IEThingWith
    , IEVar
    )
  , HsModule
    ( HsModule
    , hsmodImports
    )
  , LIE
  )
import HscTypes
  ( HsParsedModule(hpm_module)
  , Hsc
  , ModSummary(ModSummary, ms_location)
  , printOrThrowWarnings
  )
import Module(ModLocation(ModLocation, ml_hs_file))
import Outputable
  ( Outputable
  , SDoc
  , defaultUserStyle
  , neverQualify
  , ppr
  , renderWithStyle
  , text
  )
import Plugins
  ( CommandLineOption
  , Plugin
  , defaultPlugin
  , parsedResultAction
  , pluginRecompile
  , purePlugin
  )
import Prelude(error)
import SrcLoc (GenLocated(L), Located, getLoc, unLoc)
import System.FilePath.Posix (splitPath)

plugin :: Plugin
plugin =
  defaultPlugin
  { parsedResultAction = runSourceConstraints
  , pluginRecompile    = purePlugin
  }

runSourceConstraints :: [CommandLineOption]
                     -> ModSummary
                     -> HsParsedModule
                     -> Hsc HsParsedModule
runSourceConstraints _options ModSummary{ms_location = ModLocation{..}} parsedModule = do
  dynFlags <- getDynFlags

  when (allowLocation ml_hs_file) $
    liftIO
      . printOrThrowWarnings dynFlags
      $ warnings dynFlags (hpm_module parsedModule)

  pure parsedModule
  where
    allowLocation = maybe False (not . elem ".stack-work/" . splitPath)

-- | Find warnings for node
warnings
  :: (Data a, Data b, Typeable a)
  => DynFlags
  -> GenLocated a b
  -> WarningMessages
warnings dynFlags (L sourceSpan node) =
  unionManyBags
    [ maybe emptyBag mkWarning $ unlocatedWarning dynFlags node
    , maybe emptyBag unitBag   $ locatedWarning dynFlags node
    , descend node
    ]
  where
    mkWarning =
      unitBag . mkWarnMsg
        dynFlags
        (fromJust $ cast sourceSpan)
        neverQualify

    descend :: Data a => a -> WarningMessages
    descend =
      unionManyBags . gmapQ
        (descend `ext2Q` warnings dynFlags)

locatedWarning :: Data a => DynFlags -> a -> Maybe ErrMsg
locatedWarning dynFlags = mkQ empty sortedImportStatement
  where
    sortedImportStatement :: HsModule GhcPs -> Maybe ErrMsg
    sortedImportStatement HsModule{..} = sortedLocated "import statement" dynFlags hsmodImports

unlocatedWarning :: Data a => DynFlags -> a -> Maybe SDoc
unlocatedWarning dynFlags =
  mkQ empty requireDerivingStrategy
    `extQ` sortedIEThingWith dynFlags
    `extQ` sortedIEs dynFlags
    `extQ` sortedMultipleDeriving dynFlags

requireDerivingStrategy :: HsDerivingClause GhcPs -> Maybe SDoc
requireDerivingStrategy = \case
  HsDerivingClause{deriv_clause_strategy = Nothing} ->
    pure $ text "Missing deriving strategy"
  _ -> empty

sortedMultipleDeriving :: DynFlags -> [LHsDerivingClause GhcPs] -> Maybe SDoc
sortedMultipleDeriving dynFlags clauses =
  if rendered /= expected
     then pure $ text . message $ intercalate ", " expected
     else empty

  where
    message :: String -> String
    message example = "Unsorted multiple deriving, expected: " <> example

    rendered = render dynFlags <$> clauses
    expected = sort rendered

data IEClass = Module String | Type String | Operator String | Function String
  deriving stock (Eq, Ord)

sortedIEs :: DynFlags -> [LIE GhcPs] -> Maybe SDoc
sortedIEs dynFlags ies =
  if ies /= expected
    then pure . text . message $ intercalate ", " (render dynFlags <$> expected)
    else empty
  where
    message :: String -> String
    message example = "Unsorted import/export, expected: (" <> example <> ")"

    expected :: [LIE GhcPs]
    expected = sortBy (compare `on` ieClass . unLoc) ies

    classify str@('(':_) = Function str
    classify str@(x:_)   = if isUpper x then Type str else Function str
    classify []          = error "Parser error"

    ieClass :: IE GhcPs -> IEClass
    ieClass = \case
      (IEVar _xIE wrappedName) ->
        classify . render dynFlags $ unLoc wrappedName
      (IEThingAbs _xIE wrappedName) ->
        Type . render dynFlags $ unLoc wrappedName
      (IEThingAll _xIE wrappedName) ->
        Type . render dynFlags $ unLoc wrappedName
      (IEThingWith _xIE wrappedName _ieWildcard _ieWith _ieFieldLabels) ->
        Type . render dynFlags $ unLoc wrappedName
      (IEModuleContents _xIE moduleName) ->
        Module . render dynFlags $ unLoc moduleName
      ie ->
        error $ "Unsupported: " <> gshow ie

sortedIEThingWith :: DynFlags -> IE GhcPs -> Maybe SDoc
sortedIEThingWith dynFlags = \case
  (IEThingWith _xIE _wrappedName _ieWildcard ieWith _ieFieldLabels) ->
    if rendered /= expected
       then pure $ text . message $ intercalate ", " expected
       else empty
    where
      message :: String -> String
      message example = "Unsorted import/export item with list, expected: (" <> example <> ")"

      rendered = render dynFlags <$> ieWith
      expected = sort rendered
  _ -> empty

render :: Outputable a => DynFlags -> a -> String
render dynFlags outputable =
  renderWithStyle
    dynFlags
    (ppr outputable)
    (defaultUserStyle dynFlags)

sortedLocated
  :: forall a . Outputable a
  => String
  -> DynFlags
  -> [Located a]
  -> Maybe ErrMsg
sortedLocated name dynFlags nodes = mkWarning <$> violation
  where
    mkWarning :: (String, String, Located a) -> ErrMsg
    mkWarning (_rendered, expected, node) =
      mkWarnMsg
        dynFlags
        (getLoc node)
        neverQualify
        (text $ "Unsorted " <> name <> ", expected: " <> expected)

    violation = find testViolation candidates

    testViolation :: (String, String, Located a) -> Bool
    testViolation (rendered, expected, _node) = rendered /= expected

    candidates :: [(String, String, Located a)]
    candidates =
      let rendered = render dynFlags <$> nodes
      in
        zip3 rendered (sort rendered) nodes
