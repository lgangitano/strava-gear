{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wall #-}

module Strava where

import Control.Exception
import Control.Monad.IO.Class (liftIO)
import Data.Function (on)
import Data.List ((\\), nubBy)
import Data.Time
import Database.Persist
import Database.Persist.Sqlite
import Database.Persist.TH
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Strive as S

import Config

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistUpperCase|
    Bike
        name T.Text
        stravaId T.Text
        StravaBikeId stravaId
        deriving Eq Ord Show

    Component
        uniqueId T.Text
        UniqueId uniqueId
        name T.Text
        initialSeconds Int -- seconds
        initialMeters Double -- meters
        deriving Eq Ord Show

    ComponentRole
        name T.Text
        UniqueName name
        deriving Eq Ord Show

    LongtermBikeComponent
        component ComponentId
        bike BikeId
        role ComponentRoleId
        startTime UTCTime
        endTime UTCTime Maybe
        deriving Eq Ord Show

    Activity
        stravaId Int
        StravaActivityId stravaId
        name T.Text
        startTime UTCTime
        movingTime Int -- seconds
        distance Double -- meters
        gearId T.Text Maybe
        deriving Eq Ord Show

    ActivityComponent
        activity ActivityId
        component ComponentId
        role ComponentRoleId
        deriving Eq Ord Show

    HashTagBikeComponent
        tag T.Text
        component ComponentId
        role ComponentRoleId
        deriving Eq Ord Show
|]

deriving instance Eq (Unique Bike)
deriving instance Eq (Unique Component)
deriving instance Eq (Unique ComponentRole)
deriving instance Eq (Unique Activity)

testClient :: IO S.Client
testClient = S.buildClient (Just $ T.pack token)

sync :: T.Text -> S.Client -> IO ()
sync conf client = do
    Right athlete <- S.getCurrentAthlete client
    let athleteId = S.id `S.get` athlete :: Integer
        athleteBikes = S.bikes `S.get` athlete
        fileName = "athlete_" ++ show athleteId ++ ".sqlite"
    print fileName
    runSqlite (T.pack fileName) $ do
        runMigration migrateAll
        _syncBikesRes <- syncBikes athleteBikes
        _syncActivitiesRes <- syncActivities client
        syncConfig conf
        syncActivitiesComponents
        return ()

syncBikes :: [S.GearSummary] -> SqlPersistM [UpsertResult Bike]
syncBikes bikes = syncEntitiesDel $ map bike bikes
    where bike b = Bike (S.name `S.get` b) (S.id `S.get` b)

syncActivities :: S.Client -> SqlPersistM [UpsertResult Activity]
syncActivities client = do
    -- TODO: paging
    now <- liftIO $ getCurrentTime
    acts <- fromRightM $ liftIO $ S.getCurrentActivities client $
        S.with [ S.before `S.set` Just now ]
    syncEntitiesDel $ map act acts
    where
        act a = Activity
            { activityStravaId = fromIntegral $ S.id `S.get` a
            , activityName = S.name `S.get` a
            , activityStartTime = S.startDate `S.get` a
            , activityMovingTime = fromIntegral $ S.movingTime `S.get` a
            , activityDistance = S.distance `S.get` a
            , activityGearId = S.gearId `S.get` a
            }

actHashTags :: Activity -> [T.Text]
actHashTags Activity{activityName = name} =
    [ w | w <- T.words name, "#" `T.isPrefixOf` w ]

syncActivitiesComponents :: SqlPersistM ()
syncActivitiesComponents = do
    acts <- selectList [ActivityGearId !=. Nothing] []
    actComponents <- mapM syncActivityComponents acts
    wipeInsertMany $ concat actComponents

syncActivityComponents :: Entity Activity -> SqlPersistM [ActivityComponent]
syncActivityComponents act = do
    longterms <- activityLongtermComponents act
    fromtags <- activityHashtagComponents act
    return $ nubBy ((==) `on` activityComponentRole) $ fromtags ++ longterms

activityLongtermComponents :: Entity Activity -> SqlPersistM [ActivityComponent]
activityLongtermComponents (Entity k act) = do
    let gearId = maybe (error "no gear id") id $ activityGearId act
    Just bike <- getBy $ StravaBikeId gearId
    let longtermFilter =
            [ LongtermBikeComponentBike ==. entityKey bike
            , LongtermBikeComponentStartTime <=. activityStartTime act
            ] ++
            ([ LongtermBikeComponentEndTime >=. Just (activityStartTime act) ] ||.
             [ LongtermBikeComponentEndTime ==. Nothing ])
    longterms <- selectList longtermFilter []
    return [ ActivityComponent k
             (longtermBikeComponentComponent l)
             (longtermBikeComponentRole l)
           | Entity _ l <- longterms ]

activityHashtagComponents :: Entity Activity -> SqlPersistM [ActivityComponent]
activityHashtagComponents (Entity k act) = do
    let hashtagFilter = [ HashTagBikeComponentTag <-. actHashTags act ]
    fromtags <- selectList hashtagFilter []
    return [ ActivityComponent k
             (hashTagBikeComponentComponent h)
             (hashTagBikeComponentRole h)
           | Entity _ h <- fromtags ]


-- Text config (to be replaced by REST) --

syncConfig :: T.Text -> SqlPersistM ()
syncConfig conf = do
    let ls = T.lines conf
        cs = concatMap parseConf ls
    components <- fmap keptEntities $ syncEntitiesDel
        [ Component c n dur dist | ConfComponent c n dur dist <- cs ]
    roles <- fmap keptEntities $ syncEntitiesDel
        [ ComponentRole n | ConfRole n <- cs ]
    bikes <- selectList [] []
    let componentMap = Map.fromList
            [ (componentUniqueId v, k) | Entity k v <- components ]
        roleMap = Map.fromList
            [ (componentRoleName v, k) | Entity k v <- roles ]
        bikeMap = Map.fromList
            [ (bikeStravaId v, k) | Entity k v <- bikes ]
    wipeInsertMany
        [ LongtermBikeComponent (componentMap ! c)
                                (bikeMap ! b) (roleMap ! r) s e
        | ConfLongterm c b r s e <- cs ]
    wipeInsertMany
        [ HashTagBikeComponent t (componentMap ! c) (roleMap ! r)
        | ConfHashTag t c r <- cs ]

data Conf
    = ConfComponent T.Text T.Text Int Double
    | ConfRole T.Text
    | ConfLongterm T.Text T.Text T.Text UTCTime (Maybe UTCTime)
    | ConfHashTag T.Text T.Text T.Text

parseConf :: T.Text -> [Conf]
parseConf l = case T.words l of
    [] -> []
    ["component", code, name, iniDur, iniDist] ->
        [ConfComponent code name (parseDuration iniDur) (parseDist iniDist)]
    ["role", name] ->
        [ConfRole name]
    ["longterm", component, bike, role, start, end] ->
        [ConfLongterm component bike role (parseUTCTime start)
                                          (Just $ parseUTCTime end)]
    ["longterm", component, bike, role, start] ->
        [ConfLongterm component bike role (parseUTCTime start) Nothing]
    ["hashtag", tag, component, role] ->
        [ConfHashTag tag component role]
    err ->
        error $ show err

-- TODO: hours/days
parseDuration :: T.Text -> Int
parseDuration t = read $ T.unpack t

-- TODO: km
parseDist :: T.Text -> Double
parseDist t = read $ T.unpack t

parseUTCTime :: T.Text -> UTCTime
parseUTCTime t =
    parseTimeM False defaultTimeLocale (iso8601DateFormat Nothing) (T.unpack t) ()


-- Helpers --

distinct :: (Ord a) => [a] -> [a]
distinct = Set.toList . Set.fromList

fromRightM :: (Monad m, Show a) => m (Either a b) -> m b
fromRightM = fmap (either (error . show) id)

data UpsertResult rec
    = UpsertAdded (Entity rec)
    | UpsertDeleted (Key rec)
    | UpsertUpdated (Entity rec)
    | UpsertNoop (Entity rec)

deriving instance (Show (Entity rec), Show (Key rec)) => Show (UpsertResult rec)

uprepsert :: (Eq rec, Eq (Unique rec),
           PersistEntity rec, PersistEntityBackend rec ~ SqlBackend)
          => rec -> SqlPersistM (UpsertResult rec)
uprepsert rec =
    insertBy rec >>= \case
        Left dup -> do
            if entityVal dup /= rec
                then do
                    Nothing <- replaceUnique (entityKey dup) rec
                    return $ UpsertUpdated dup
                else
                    return $ UpsertNoop dup
        Right key ->
            return $ UpsertAdded $ Entity key rec

delEntities :: (PersistEntity rec, PersistEntityBackend rec ~ SqlBackend)
               => [UpsertResult rec] -> SqlPersistM [UpsertResult rec]
delEntities res = do
    allKeys <- selectKeysList [] []
    let delKeys = allKeys \\ map entityKey (keptEntities res)
    mapM (\k -> delete k >> return (UpsertDeleted k)) delKeys

keptEntities :: [UpsertResult rec] -> [Entity rec]
keptEntities = concatMap $ \case
    UpsertAdded   e -> [e]
    UpsertDeleted _ -> []
    UpsertUpdated e -> [e]
    UpsertNoop    e -> [e]

syncEntities :: (Eq rec, Eq (Unique rec),
                 PersistEntity rec, PersistEntityBackend rec ~ SqlBackend)
                => [rec] -> SqlPersistM [UpsertResult rec]
syncEntities = mapM uprepsert

syncEntitiesDel :: (Eq rec, Eq (Unique rec),
                    PersistEntity rec, PersistEntityBackend rec ~ SqlBackend)
                   => [rec] -> SqlPersistM [UpsertResult rec]
syncEntitiesDel recs = do
    syncRes <- syncEntities recs
    delRes <- delEntities syncRes
    return $ syncRes ++ delRes

wipeInsertMany :: forall rec.
                  (PersistEntity rec, PersistEntityBackend rec ~ SqlBackend)
                  => [rec] -> SqlPersistM ()
wipeInsertMany recs = do
    deleteWhere ([] :: [Filter rec])
    insertMany_ recs

(!) :: (Ord k, Show k, Show a) => Map.Map k a -> k -> a
m ! v = unsafePerformIO $ try (evaluate (m Map.! v)) >>= \case
    Right x -> return x
    Left (e :: SomeException) ->
        error $ show m ++ " ! " ++ show v ++ ": " ++ show e
