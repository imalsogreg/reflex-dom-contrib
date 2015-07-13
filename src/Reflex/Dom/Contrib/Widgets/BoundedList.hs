{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiWayIf                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE RecursiveDo               #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE TypeFamilies              #-}

module Reflex.Dom.Contrib.Widgets.BoundedList
  ( boundedSelectList
  , boundedSelectList'
  , mkHiding
  , keyToMaybe
  ) where

------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Monad
import           Data.Bifunctor
import           Data.List
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Monoid
import           Reflex
import           Reflex.Dom
------------------------------------------------------------------------------
import           Reflex.Contrib.Interfaces
------------------------------------------------------------------------------


------------------------------------------------------------------------------
findCurItem :: Ord k => Map k v -> k -> Maybe (k,v)
findCurItem m k = M.lookupLE k m <|> M.lookupGT k m


-- Limit on the number of items in the DOM.  Might make this more
-- sophisticated in the future.
type Limit = Maybe Int

-- An Int counter that we use in lieu of a timestamp for LRU calculations
type BornAt = Int


------------------------------------------------------------------------------
limitMap :: Ord k => Map k v -> Limit -> Map k v
limitMap m Nothing = m
limitMap m (Just lim) = M.fromList $ take lim $ M.toList m


------------------------------------------------------------------------------
boundedInsert
    :: Ord k
    => Limit
    -> (BornAt, (k,v))
    -> Map k (BornAt,v)
    -> Map k (BornAt,v)
boundedInsert Nothing (c, (k, v)) m = M.insert k (c,v) m
boundedInsert (Just lim) (c, (k, v)) m =
    if M.size m < lim then ins m else ins pruned
  where
    ins = M.insert k (c,v)
    pruned = M.fromList $ tail $ sortOn (fst . snd) $ M.toList m


------------------------------------------------------------------------------
-- | A widget with generalized handling for dynamically sized lists.  There
-- are many possible approaches to rendering lists that have one visible
-- current selection.  One way is to keep all the items in the DOM and manage
-- the selection by managing visibility through something like display:none or
-- visibility:hidden.  Another way is to only keep the currently selected item
-- in the DOM and swap it out every time the selection is changed.
--
-- The problem with keeping all items in the DOM is that this might use too
-- much memory either because there are many items or the items are large.
-- The problem with keeping only the currently selected item in the DOM is
-- that performance might be too slow if removing the old item's DOM elements
-- and building the new one takes too long.
--
-- This widget provides a middle ground.  It lets the user decide how many
-- elements are kept in the DOM at any one time and prunes the least recently
-- used items if that size is exceeded.
boundedSelectList'
    :: (MonadWidget t m, Show k, Ord k, Show v)
    => Event t (Map k v -> Map k v)
    -- ^ Event that updates individual item values
    -> Limit
    -- ^ Maximum number of items to keep in the DOM at a time
    -> Dynamic t k
    -- ^ Currently selected item
    -> ReflexMap t k v
    -- ^ Interface for updating the list
    -> (k -> Dynamic t v -> Dynamic t Bool -> m a)
    -- ^ Function to render a single item
    -> m (Dynamic t (Map k a))
boundedSelectList' updateEvent itemLimit curSelected
                  ReflexMap{..} renderSingle = do
    -- Map holding the full item list.
    items <- foldDyn ($) rmInitialItems $ leftmost
      [ M.union . M.fromList <$> rmInsertItems
      , rmDeleteFunc <$> rmDeleteItems
      , updateEvent
      ]
    
    counter <- count $ updated curSelected
    curItem <- combineDyn findCurItem items curSelected
    let addCounter c (k,v) = (k, ((-c), v))
        taggedInitial = M.fromList $ zipWith addCounter [1..] $
                          M.toList rmInitialItems
    let initMap = limitMap taggedInitial itemLimit
    activeItems <- foldDyn ($) initMap $
      boundedInsert itemLimit <$>
      attachDyn counter (fmapMaybe id $ updated curItem)
    selectViewListWithKey curSelected activeItems wrapSingle
  where
    wrapSingle k v b = do
        v' <- mapDyn snd v
        renderSingle k v' b


------------------------------------------------------------------------------
-- | Implements a common use of boundedSelectList' where only the currently
-- selected item from a list is displayed.  In this case a Dynamic
-- representing the current selection is used to drive insertions and they are
-- never deleted externally.  Instead of returning a Map of all the item
-- results, this function only returns the result for the item that is
-- currently selected.
boundedSelectList
    :: (MonadWidget t m, Show k, Ord k, Show v)
    => Limit
    -- ^ Maximum number of items to keep in the DOM at a time
    -> Dynamic t a
    -- ^ Currently selected item.  New items are added to the list when the
    -- currently selected item changes and the new item is not already in the
    -- list.
    -> (a -> k)
    -- ^ Gets the portion of a used as the key for the map of items
    -> (a -> Maybe a)
    -- ^ Decides whether to run expensiveGetNew in the case that the key is
    -- already in the cache.
    -> (Event t a -> m (Event t (k,v)))
    -- ^ Gets a new key/value pair.  This function is run when curSelected
    -- changes.
    -> b
    -- ^ Default value to return if nothing is in the list
    -> (k -> Dynamic t v -> Dynamic t Bool -> m b)
    -- ^ Function to render a single item
    -> m (Dynamic t b)
boundedSelectList itemLimit curSelected getKey shouldRunExpensive
                  expensiveGetNew defaultVal renderSingle = do
    pb <- getPostBuild
    e0 <- expensiveGetNew $ tagDyn curSelected pb
    rec
      let insertEvent = fmapMaybe id $
            attachDynWith isAlreadyPresent res (updated curSelected)
      newVal <- expensiveGetNew insertEvent
      let rm = ReflexMap mempty ((:[]) <$> leftmost [newVal, e0]) never
      curK <- mapDyn getKey curSelected
      res :: Dynamic t (Map k b) <-
        boundedSelectList' never itemLimit curK rm renderSingle
    combineDyn getCurrent curSelected res
  where
    getCurrent cur listMap =
        case M.lookup (getKey cur) listMap of
          Nothing -> defaultVal
          Just v -> v
    isAlreadyPresent fieldListMap cur =
        case M.lookup (getKey cur) fieldListMap of
          Nothing -> Just cur
          Just _ -> shouldRunExpensive cur


------------------------------------------------------------------------------
-- | Wraps a widget with a dynamically hidden div that uses display:none to
-- hide.
mkHiding
    :: (MonadWidget t m)
    => Map String String
    -> m a
    -> Dynamic t Bool
    -- ^ Function of a dynamic active flag
    -> m a
mkHiding staticAttrs w active = do
    attrs <- mapDyn mkAttrs active
    elDynAttr "div" attrs w
  where
    mkAttrs True = staticAttrs
    mkAttrs False = staticAttrs <> "style" =: "display:none"


------------------------------------------------------------------------------
-- | Small helper for a common pattern that comes up with the expensiveGetNew
-- parameter to boundedSelectList.
keyToMaybe
    :: MonadWidget t m
    => (Event t a -> m (Event t (b,c)))
    -> Event t (Maybe a)
    -> m (Event t (Maybe b, c))
keyToMaybe f = liftM (fmap $ first Just) . f . fmapMaybe id
