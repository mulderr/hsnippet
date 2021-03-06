{-# LANGUAGE ConstraintKinds          #-}
{-# LANGUAGE CPP                      #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE JavaScriptFFI            #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE RecordWildCards          #-}
{-# LANGUAGE RecursiveDo              #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE UndecidableInstances     #-}

module HSnippet.Imports where

------------------------------------------------------------------------------
import           Control.Lens
import           Control.Monad.Trans
import           Data.Char
import           Data.List
import           Data.List.Split
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Maybe
import           Data.Monoid
import           Data.Ord
import           Data.String.Conv
import qualified Data.Text as T
import           GHCJS.DOM.Types hiding (Event, Text)
#ifdef ghcjs_HOST_OS
import           GHCJS.Types
#endif
import           Reflex
import           Reflex.Dom
import           Reflex.Dom.Contrib.Utils
import           Safe
------------------------------------------------------------------------------
import           HSnippet.FrontendState
import           HSnippet.Shared.Types.Package
import           HSnippet.Shared.Types.SnippetImport
------------------------------------------------------------------------------


------------------------------------------------------------------------------
activateSemUiDropdown :: String -> IO ()
#ifdef ghcjs_HOST_OS
activateSemUiDropdown = js_activateSemUiDropdown . toJSString

foreign import javascript unsafe
  "$($1).dropdown({fullTextSearch: true});"
  js_activateSemUiDropdown :: JSString -> IO ()
#else
activateSemUiDropdown =
  error "activateSemUiDropdown: can only be used with GHCJS"
#endif


defaultImports :: Map Int SnippetImport
defaultImports = M.fromList $ zip [0..]
    [ p "Control.Lens"
    , p "Control.Monad"
    , p "Data.Aeson"
    , p "Data.Aeson.TH"
    , p "Data.Colour.Palette.BrewerSet"
    , e "Data.Map" ["Map"]
    , q "Data.Map" "M"
    , p "Data.String.Conv"
    , e "Data.Text" ["Text"]
    , q "Data.Text" "T"
    , p "Data.Monoid"
    , p "Diagrams.Backend.Reflex"
    , q "Diagrams.Prelude" "D"
    , p "GHC.Generics"
    , p "Reflex"
    , p "Reflex.Dom"
    , p "Reflex.Dom.Contrib.KeyEvent"
    , p "Reflex.Dom.Contrib.Pagination"
    , p "Reflex.Dom.Contrib.Utils"
    , p "Reflex.Dom.Contrib.Widgets.EditInPlace"
    , p "Reflex.Dom.Contrib.Widgets.Svg"
    , p "Reflex.Dom.Contrib.Xhr"
    ]
  where
    p m = SnippetImport m NoExtra
    q m a = SnippetImport m (QualifiedName a)
    e m fs = SnippetImport m (ExplicitSymbols fs)

data ImportsOut t = ImportsOut
    { ioutImports       :: Dynamic t [SnippetImport]
    , ioutRefresh       :: Event t ()
    , ioutModuleUpdates :: Event t Module
    }

------------------------------------------------------------------------------
importsWidget
    :: MonadWidget t m
    => FrontendState t
    -> m (ImportsOut t)
importsWidget fs = do
    divClass "ui small form" $ do
      (newImport, refreshImports, moduleUpdates) <- importInput fs
      let order = sortBy (comparing importModuleName)
      let addNew i im = if M.null im
                          then M.singleton (0 :: Int) i
                          else M.insert (fst (M.findMax im) + 1) i im
      rec imports <- foldDyn ($) defaultImports $ leftmost
                       [ addNew <$> newImport
                       , M.delete <$> delImport
                       ]
          res <- divClass "ui list" $ listViewWithKey imports $ \_ iDyn -> do
            elClass "pre" "item" $ do
              (minusEl,_) <- elAttr' "i" ("class" =: "minus icon") blank
              dynText =<< mapDyn renderImport iDyn
              return $ domEvent Click minusEl
          let delImport = fmapMaybe id $ fmap fst . headMay . M.toList <$> res
      sImports <- mapDyn (order . M.elems) imports
      return $ ImportsOut sImports refreshImports moduleUpdates


data ImportType = PlainImport
                | Qualified
                | Hiding
                | Explicit
  deriving (Eq,Ord,Show,Read)


importTypeNames :: Map ImportType String
importTypeNames = M.fromList
    [ (PlainImport, "plain")
    , (Qualified, "qualified")
    , (Hiding, "hiding")
    , (Explicit, "explicit")
    ]

funcList :: [String]
funcList = ["Maybe", "Either", "listToMaybe", "catMaybes"]

mkMap :: [String] -> Map String String
mkMap = M.fromList . map (\nm -> (nm, nm))

packageToModules :: Package -> [(Maybe String, String)]
packageToModules Package{..} = map (p . moduleName) packageModules
  where
    p t = let n = toS t in (Just n, n)


moduleMap :: [Package] -> Map (Maybe String) String
moduleMap ps = M.fromList $ d : concatMap packageToModules ps
  where
    d = (Nothing, "")

-- | Wrapper around the reflex-dom dropdown that calls the sem-ui dropdown
-- function after the element is built.
semUiDropdown
    :: (Ord a, Read a, Show a, MonadWidget t m)
    => String
       -- ^ Element id.  Ideally this should be randomly generated instead
       -- of passed in as an argument, but for now this approach is easier.
    -> a
       -- ^ Initial value
    -> Dynamic t (Map a String)
    -> Map String [Char]
    -> m (Dynamic t a)
semUiDropdown elId iv vals attrs = do
    let f vs = semUiDropdown' elId iv vs attrs
    res <- dyn =<< mapDyn f (traceDynWith (((elId ++ " values changed ") ++) . show . length) vals)
    joinDyn <$> holdDyn (constDyn iv) res

-- | Wrapper around the reflex-dom dropdown that calls the sem-ui dropdown
-- function after the element is built.
semUiDropdown'
    :: (Ord a, Read a, Show a, MonadWidget t m)
    => String
       -- ^ Element id.  Ideally this should be randomly generated instead
       -- of passed in as an argument, but for now this approach is easier.
    -> a
       -- ^ Initial value
    -> Map a String
    -> Map String [Char]
    -> m (Dynamic t a)
semUiDropdown' elId iv vals attrs = do
    d <- dropdown iv (constDyn vals) $ def &
      attributes .~ (constDyn $ attrs <> ("id" =: elId))
    pb <- getPostBuild
    putDebugLn $ elId ++ " initialized with " ++ (show $ length vals) ++ " values"
    performEvent_ (liftIO (activateSemUiDropdown ('#':elId)) <$ pb)
    return $ value d

data ExportStatus = PendingExports String
                  | ExportList (Map String String)

------------------------------------------------------------------------------
importInput
    :: MonadWidget t m
    => FrontendState t
    -> m (Event t SnippetImport, Event t (), Event t Module)
importInput fs = do
    let initial = (PendingExports "", PlainImport)
    divClass "fields" $ do
      rec attrs <- mapDyn mkAttrs $ value v
          (n, refresh) <- elDynAttr "div" attrs $ do
            clk <- el "label" $ do
              text "Module Name"
              (e,_) <- elAttr' "i" ("class" =: "refresh icon") blank
              return $ domEvent Click e
            mm <- mapDyn moduleMap (fsPackages fs)
            res <- semUiDropdown "import-search" Nothing mm
              ("class" =: "ui search dropdown")
            return (res, clk)
          es <- foldDyn ($) (PendingExports "") $ leftmost
                  [ (\n _ -> PendingExports $ fromMaybe "" n) <$> updated n
                  , getExports <$> updated (fsModuleExports fs)
                  ]
          v <- divClass "three wide field" $ do
            el "label" $ text "Import Type"
            dropdown (snd initial) (constDyn importTypeNames) $
                     def & attributes .~ constDyn ("class" =: "ui fluid dropdown")
          arg <- combineDyn (,) es $ value v
          ie <- widgetHoldHelper (uncurry importDetails) initial (updated arg)
          si <- combineDyn (\nm e -> SnippetImport <$> nm <*> pure e) n $
                           joinDyn ie
      clk <- divClass "one wide field" $ do
        elDynHtml' "label" $ constDyn "&nbsp;"
        (e,_) <- elAttr' "button" ("class" =: "ui icon button") $
          elClass "i" "plus icon" blank
        return $ domEvent Click e
      return (fmapMaybe id $ tagDyn si clk, refresh, Module . toS <$> fmapMaybe id (updated n))
  where
    mkAttrs PlainImport = "class" =: "twelve wide field"
    mkAttrs Qualified = "class" =: "fourteen wide field"
    mkAttrs _ = "class" =: "eight wide field"

getExports :: Map Module [Export] -> ExportStatus -> ExportStatus
getExports mm (PendingExports "") = PendingExports ""
getExports mm (ExportList es) = ExportList es
getExports mm (PendingExports m) =
    case M.lookup (Module $ T.pack m) mm of
      Nothing -> PendingExports m
      Just es -> ExportList $ M.fromList $ map (tup . T.unpack . exportName) es
  where
    tup n = (n,n)


importDetails
    :: MonadWidget t m
    => ExportStatus
    -> ImportType
    -> m (Dynamic t ImportExtra)
importDetails _ PlainImport = return (constDyn NoExtra)
importDetails _ Qualified = do
  divClass "two wide field" $ do
    el "label" $ text "As"
    mapDyn QualifiedName . value =<< textInput def
importDetails (PendingExports _) _ = do
  divClass "four wide field" $ do
    el "label" $ text "Hiding"
    v <- semUiDropdown "hiding-symbols" "" (constDyn mempty) $
        ("multiple" =: " " <> "class" =: "ui loading fluid dropdown")
    mapDyn (HidingSymbols . splitOn "," . filter (not . isSpace)) v
importDetails (ExportList exports) Hiding = do
  divClass "four wide field" $ do
    el "label" $ text "Hiding"
    v <- semUiDropdownMulti "hiding-symbols" "" (constDyn exports) $
        ("multiple" =: " " <> "class" =: "ui fluid dropdown")
    mapDyn (HidingSymbols . splitOn "," . filter (not . isSpace)) v
importDetails (ExportList exports) Explicit = do
  divClass "four wide field" $ do
    el "label" $ text "Symbols"
    v <- semUiDropdownMulti "explicit-symbols" "" (constDyn exports) $
             ("multiple" =: " " <> "class" =: "ui fluid dropdown")
    mapDyn (ExplicitSymbols . splitOn "," . filter (not . isSpace)) $ traceDyn "explicit" v

-- Multi-select sem-ui dropdown is not working properly yet.  Not sure how
-- to get the current value.

-- | Wrapper around the reflex-dom dropdown that calls the sem-ui dropdown
-- function after the element is built.
semUiDropdownMulti
    :: (Ord a, Read a, Show a, MonadWidget t m)
    => String
       -- ^ Element id.  Ideally this should be randomly generated instead
       -- of passed in as an argument, but for now this approach is easier.
    -> a
       -- ^ Initial value
    -> Dynamic t (Map a String)
    -> Map String [Char]
    -> m (Dynamic t String)
semUiDropdownMulti elId iv vals attrs = do
    let f vs = semUiDropdownMulti' elId iv vs attrs
    res <- dyn =<< mapDyn f (traceDynWith (((elId ++ " values changed ") ++) . show . length) vals)
    joinDyn <$> holdDyn (constDyn $ show iv) res

-- | Wrapper around the reflex-dom dropdown that calls the sem-ui dropdown
-- function after the element is built.
semUiDropdownMulti'
    :: (Ord a, Read a, Show a, MonadWidget t m)
    => String
       -- ^ Element id.  Ideally this should be randomly generated instead
       -- of passed in as an argument, but for now this approach is easier.
    -> a
       -- ^ Initial value
    -> Map a String
    -> Map String [Char]
    -> m (Dynamic t String)
semUiDropdownMulti' elId iv vals attrs = do
    d <- dropdown (show iv) (constDyn $ M.mapKeys show vals) $ def &
      attributes .~ (constDyn $ attrs <> ("id" =: elId))
    pb <- getPostBuild
    putDebugLn $ elId ++ " initialized with " ++ (show $ length vals) ++ " values"
    performEvent_ (liftIO (activateSemUiDropdown ('#':elId)) <$ pb)
    return $ value d
