-- =====================================================
-- TRANSPORTATION DATABASE PROJECT
-- COMPLETE DATABASE BUILD SCRIPT (CSDS 341)
-- =====================================================
--
-- Purpose
--   Builds the normalized NYC transportation database from the two
--   staging tables loaded by the Python notebook:
--     taxi_staging : 120,000 sampled NYC Yellow Taxi trips (2024)
--     bike_staging : 120,000 sampled Citi Bike trips (2024)
--
-- Prerequisite
--   Run the notebook through Section 5 (Loading the Staging Tables)
--   so that taxi_staging and bike_staging exist.
--
-- !! WARNING: DESTRUCTIVE !!
--   Section 0 DROPS and recreates every permanent table, including
--   prediction and prediction_feature. Running this script deletes all
--   stored model predictions. Re-insert them afterwards with notebook
--   Section 9.2 (set RUN_PREDICTION_INSERT = True for that one run).
--
-- Script outline
--   0        Drop existing project tables
--   1        Verify staging data
--   2-11     Create schema (dimensions, trip supertype, taxi/bike
--            subtypes, feature stores, predictions)
--   12-16    Verify schema; test functional dependencies
--   17-19    Populate dimension tables
--   20-27    Populate TRIP, TAXI and BIKE
--   28       Populate wide feature store
--   29-38    Analytics view, analytical queries, index benchmarks
--   39       Populate normalized feature store
--   40       Final validation
--
-- Conventions
--   duration      : seconds (queries divide by 60 to report minutes)
--   distance      : miles; NULL for bike trips (not in Citi Bike data)
--   day_of_week   : PostgreSQL DOW, 0 = Sunday ... 6 = Saturday
--   season        : meteorological (Dec-Feb Winter, Mar-May Spring,
--                   Jun-Aug Summer, Sep-Nov Fall)
--   prediction_audit : automatically records each inserted prediction
-- =====================================================

-- =====================================================
-- 0. DROP EXISTING PROJECT TABLES
-- Child tables are dropped before the tables they reference;
-- CASCADE also removes dependent views and foreign keys.
-- taxi_staging and bike_staging are intentionally preserved.
-- =====================================================

DROP FUNCTION IF EXISTS log_prediction_insert() CASCADE;
DROP TABLE IF EXISTS prediction_audit CASCADE;

DROP TABLE IF EXISTS prediction_feature CASCADE;
DROP TABLE IF EXISTS trip_feature_wide CASCADE;
DROP TABLE IF EXISTS trip_feature CASCADE;
DROP TABLE IF EXISTS prediction CASCADE;
DROP TABLE IF EXISTS bike CASCADE;
DROP TABLE IF EXISTS taxi CASCADE;
DROP TABLE IF EXISTS trip CASCADE;
DROP TABLE IF EXISTS feature CASCADE;
DROP TABLE IF EXISTS user_type CASCADE;
DROP TABLE IF EXISTS station CASCADE;
DROP TABLE IF EXISTS time_dimension CASCADE;

-- Temporary helper tables (Sections 20-24), in case the script is
-- rerun within the same session.
DROP TABLE IF EXISTS taxi_source;
DROP TABLE IF EXISTS bike_source;
DROP TABLE IF EXISTS trip_load_final;
DROP TABLE IF EXISTS trip_source_mapping;

DROP INDEX IF EXISTS idx_trip_mode;


-- =====================================================
-- 1. VERIFY STAGING DATA
-- Expected: 120,000 rows in each staging table.
-- =====================================================

SELECT COUNT(*) AS taxi_staging_count FROM taxi_staging;
SELECT COUNT(*) AS bike_staging_count FROM bike_staging;

SELECT * FROM taxi_staging LIMIT 10;
SELECT * FROM bike_staging LIMIT 10;


-- =====================================================
-- 2. TIME DIMENSION
-- One row represents one calendar date and hour.
-- Trips reference it for their start and end times, so date
-- attributes (weekday, weekend, season) are stored once rather
-- than repeated in every trip.
-- =====================================================

CREATE TABLE time_dimension (
    time_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date          DATE NOT NULL,
    year          INTEGER NOT NULL,
    month         INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    day           INTEGER NOT NULL CHECK (day BETWEEN 1 AND 31),
    day_of_week   INTEGER NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    hour          INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),
    is_weekend    BOOLEAN NOT NULL,
    season        VARCHAR(10),
    UNIQUE (date, hour)                -- natural key
);


-- =====================================================
-- 3. STATION
-- Citi Bike docking stations. Removes the transitive dependency
-- station_id -> station_name from the bike records (see Section 13).
-- =====================================================

CREATE TABLE station (
    station_id VARCHAR(50) PRIMARY KEY,
    name       VARCHAR(255)
);


-- =====================================================
-- 4. USER TYPE
-- Citi Bike rider category: member (subscriber) or casual.
-- =====================================================

CREATE TABLE user_type (
    user_type_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    is_subscriber BOOLEAN NOT NULL UNIQUE
);


-- =====================================================
-- 5. TRIP (supertype)
-- One row per trip of either mode. Attributes shared by both modes
-- live here; mode-specific attributes live in TAXI or BIKE.
-- =====================================================

CREATE TABLE trip (
    trip_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    distance       DOUBLE PRECISION,           -- miles; NULL for bike
    start_time_id  BIGINT REFERENCES time_dimension(time_id),
    end_time_id    BIGINT REFERENCES time_dimension(time_id),
    mode           VARCHAR(10) NOT NULL
                   CHECK (mode IN ('taxi', 'bike')),
    duration       DOUBLE PRECISION            -- seconds
);


-- =====================================================
-- 6. TAXI (subtype of TRIP)
-- trip_id is both the primary key and a foreign key to TRIP,
-- giving a one-to-one relationship.
-- =====================================================

CREATE TABLE taxi (
    trip_id              BIGINT PRIMARY KEY REFERENCES trip(trip_id),
    start_location_id    INTEGER,          -- TLC pickup zone (PULocationID)
    end_location_id      INTEGER,          -- TLC drop-off zone (DOLocationID)
    total_amount         NUMERIC(10, 2),
    congestion_surcharge NUMERIC(10, 2),
    source_month         DATE              -- first day of the source month
);


-- =====================================================
-- 7. BIKE (subtype of TRIP)
-- =====================================================

CREATE TABLE bike (
    trip_id          BIGINT PRIMARY KEY REFERENCES trip(trip_id),
    ride_id          VARCHAR(50) UNIQUE,   -- Citi Bike's own trip identifier
    start_station_id VARCHAR(50) REFERENCES station(station_id),
    end_station_id   VARCHAR(50) REFERENCES station(station_id),
    user_type_id     SMALLINT REFERENCES user_type(user_type_id),
    source_month     DATE                  -- first day of the source month
);


-- =====================================================
-- 8. NORMALIZED FEATURE STORE (row-oriented)
-- FEATURE describes each model feature; TRIP_FEATURE stores one
-- row per (trip, feature) pair. New features can be added as rows
-- without changing the schema. Values are stored as TEXT so that
-- one column can hold features of any type.
-- =====================================================

CREATE TABLE feature (
    feature_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feature_name  VARCHAR(100) NOT NULL UNIQUE,
    feature_type  VARCHAR(50),
    description   TEXT
);

CREATE TABLE trip_feature (
    trip_id       BIGINT REFERENCES trip(trip_id),
    feature_id    BIGINT REFERENCES feature(feature_id),
    feature_value TEXT,
    PRIMARY KEY (trip_id, feature_id)
);


-- =====================================================
-- 9. WIDE FEATURE STORE (materialized)
-- One row per trip, with all five features as typed columns.
-- Faster to read than TRIP_FEATURE because no pivot is needed,
-- but adding a feature requires a schema change.
-- The table is created here but populated after trip loading.
-- =====================================================

CREATE TABLE trip_feature_wide (
    trip_id      BIGINT PRIMARY KEY REFERENCES trip(trip_id),
    hour         INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),
    day_of_week  INTEGER NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    is_weekend   BOOLEAN NOT NULL,
    month        INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    season       VARCHAR(10) NOT NULL
                 CHECK (season IN ('Winter', 'Spring', 'Summer', 'Fall'))
);


-- =====================================================
-- 10. PREDICTION
-- One row per model prediction. Populated from the notebook
-- (Section 9.2), not by this script.
-- =====================================================

CREATE TABLE prediction (
    prediction_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_id          BIGINT NOT NULL REFERENCES trip(trip_id),
    prediction_time  TIMESTAMP NOT NULL,
    predicted_mode   VARCHAR(10) NOT NULL
                     CHECK (predicted_mode IN ('taxi', 'bike')),
    bike_probability DOUBLE PRECISION
                     CHECK (bike_probability BETWEEN 0 AND 1),
    taxi_probability DOUBLE PRECISION
                     CHECK (taxi_probability BETWEEN 0 AND 1)
);


-- =====================================================
-- 11. PREDICTION FEATURE
-- The feature values each prediction was based on, in the same
-- row-oriented format as TRIP_FEATURE. Populated from the notebook.
-- =====================================================

CREATE TABLE prediction_feature (
    prediction_id BIGINT REFERENCES prediction(prediction_id),
    feature_id    BIGINT REFERENCES feature(feature_id),
    feature_value TEXT,
    PRIMARY KEY (prediction_id, feature_id)
);


-- =====================================================
-- 11A. PREDICTION AUDIT
-- Records every newly inserted prediction automatically.
-- The trigger writes one audit row for each prediction.
-- This table is populated by the trigger, not directly
-- by the Python notebook.
-- =====================================================

CREATE TABLE prediction_audit (
    audit_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prediction_id  BIGINT NOT NULL,
    predicted_mode VARCHAR(10) NOT NULL,
    audit_time     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    action         VARCHAR(10) NOT NULL
);


-- Automatically log every new prediction.

CREATE OR REPLACE FUNCTION log_prediction_insert()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO prediction_audit (
        prediction_id,
        predicted_mode,
        action
    )
    VALUES (
        NEW.prediction_id,
        NEW.predicted_mode,
        'INSERT'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER prediction_insert_trigger
AFTER INSERT ON prediction
FOR EACH ROW
EXECUTE FUNCTION log_prediction_insert();


-- =====================================================
-- 12. VERIFY TABLE CREATION
-- Lists every base table in the public schema.
-- =====================================================

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;


-- =====================================================
-- 13. FUNCTIONAL DEPENDENCY TESTS
-- BIKE STAGING
-- Each query looks for violations of a candidate FD X -> Y:
-- values of X associated with more than one distinct Y.
-- An empty result means the FD holds in the sample.
-- =====================================================

-- start_station_id --> start_station_name

SELECT
    start_station_id,
    COUNT(DISTINCT start_station_name) AS name_count
FROM bike_staging
WHERE start_station_id IS NOT NULL
  AND start_station_name IS NOT NULL
GROUP BY start_station_id
HAVING COUNT(DISTINCT start_station_name) > 1;


-- end_station_id --> end_station_name

SELECT
    end_station_id,
    COUNT(DISTINCT end_station_name) AS name_count
FROM bike_staging
WHERE end_station_id IS NOT NULL
  AND end_station_name IS NOT NULL
GROUP BY end_station_id
HAVING COUNT(DISTINCT end_station_name) > 1;


-- ride_id --> started_at, ended_at, start_station_id,
--              end_station_id, member_casual
-- (Confirms ride_id is a candidate key for a bike trip.)

SELECT
    ride_id,
    COUNT(DISTINCT (
        started_at,
        ended_at,
        start_station_id,
        end_station_id,
        member_casual
    )) AS name_count
FROM bike_staging
WHERE ride_id IS NOT NULL
  AND started_at IS NOT NULL
  AND ended_at IS NOT NULL
  AND start_station_id IS NOT NULL
  AND end_station_id IS NOT NULL
  AND member_casual IS NOT NULL
GROUP BY ride_id
HAVING COUNT(DISTINCT (
    started_at,
    ended_at,
    start_station_id,
    end_station_id,
    member_casual
)) > 1;


-- =====================================================
-- 14. FUNCTIONAL DEPENDENCY TESTS
-- TAXI STAGING
-- The taxi data has no trip identifier, so these tests check
-- whether distance is determined by location and time.
-- =====================================================

-- (PULocationID, DOLocationID) --> distance
-- Expected to fail (returns rows): trips between the same two
-- zones can have different distances.

SELECT
    "PULocationID",
    "DOLocationID",
    COUNT(DISTINCT trip_distance) AS name_count
FROM taxi_staging
WHERE "PULocationID" IS NOT NULL
  AND "DOLocationID" IS NOT NULL
  AND trip_distance IS NOT NULL
GROUP BY "PULocationID", "DOLocationID"
HAVING COUNT(DISTINCT trip_distance) > 1;


-- (pickup, dropoff, PU location, DO location) --> distance
-- Adding the pickup and drop-off timestamps identifies the trip.

SELECT
    "tpep_pickup_datetime",
    "tpep_dropoff_datetime",
    "PULocationID",
    "DOLocationID",
    COUNT(DISTINCT trip_distance) AS name_count
FROM taxi_staging
WHERE "tpep_pickup_datetime" IS NOT NULL
  AND "tpep_dropoff_datetime" IS NOT NULL
  AND "PULocationID" IS NOT NULL
  AND "DOLocationID" IS NOT NULL
  AND trip_distance IS NOT NULL
GROUP BY
    "tpep_pickup_datetime",
    "tpep_dropoff_datetime",
    "PULocationID",
    "DOLocationID"
HAVING COUNT(DISTINCT trip_distance) > 1;


-- =====================================================
-- 15. STAGING TABLE COUNTS AND SCHEMA CHECK
-- Column names and data types of the staging and core tables,
-- followed by staging row counts.
-- =====================================================

SELECT
    table_name,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
      'taxi_staging',
      'bike_staging',
      'trip',
      'taxi',
      'bike',
      'station',
      'time_dimension',
      'user_type'
  )
ORDER BY table_name, ordinal_position;


SELECT 'taxi_staging' AS table_name, COUNT(*) AS row_count
FROM taxi_staging

UNION ALL

SELECT 'bike_staging', COUNT(*)
FROM bike_staging;


-- =====================================================
-- 16. CHECK STATION NAME CONSISTENCY
-- Combines start and end stations and lists any station_id that
-- appears with more than one name. Any such conflicts are
-- resolved in Section 17 by keeping MIN(name).
-- =====================================================

WITH all_stations AS (
    SELECT
        start_station_id AS station_id,
        start_station_name AS name
    FROM bike_staging

    UNION ALL

    SELECT
        end_station_id,
        end_station_name
    FROM bike_staging
)
SELECT
    station_id,
    COUNT(DISTINCT name) AS name_count
FROM all_stations
WHERE station_id IS NOT NULL
  AND name IS NOT NULL
GROUP BY station_id
HAVING COUNT(DISTINCT name) > 1;


-- =====================================================
-- 17. POPULATE STATION
-- One row per distinct station_id from either end of a trip.
-- MIN(name) picks one name deterministically if a station has
-- several.
-- =====================================================

INSERT INTO station (station_id, name)
SELECT
    station_id,
    MIN(name) AS name
FROM (
    SELECT
        start_station_id AS station_id,
        start_station_name AS name
    FROM bike_staging

    UNION ALL

    SELECT
        end_station_id,
        end_station_name
    FROM bike_staging
) AS all_stations
WHERE station_id IS NOT NULL
  AND name IS NOT NULL
GROUP BY station_id;

SELECT * FROM station;


-- =====================================================
-- 18. POPULATE USER TYPE
-- Maps member_casual text to a boolean: member = TRUE,
-- casual = FALSE. Produces at most two rows.
-- =====================================================

INSERT INTO user_type (is_subscriber)
SELECT DISTINCT
    CASE
        WHEN member_casual = 'member' THEN TRUE
        WHEN member_casual = 'casual' THEN FALSE
    END
FROM bike_staging
WHERE member_casual IN ('member', 'casual');

SELECT * FROM user_type;


-- =====================================================
-- 19. POPULATE TIME DIMENSION
-- Collects every distinct (date, hour) that appears as a start
-- or end time in either staging table. UNION removes duplicates
-- across the four sources. Derived attributes (weekday, weekend,
-- season) are computed once here.
-- Bike timestamps are stored as text in staging, so they are
-- cast to TIMESTAMP first.
-- =====================================================

INSERT INTO time_dimension (
    date,
    year,
    month,
    day,
    day_of_week,
    hour,
    is_weekend,
    season
)
SELECT DISTINCT
    calendar_date,
    EXTRACT(YEAR FROM calendar_date)::INTEGER,
    EXTRACT(MONTH FROM calendar_date)::INTEGER,
    EXTRACT(DAY FROM calendar_date)::INTEGER,
    EXTRACT(DOW FROM calendar_date)::INTEGER,
    trip_hour,
    EXTRACT(DOW FROM calendar_date) IN (0, 6),      -- Sunday or Saturday
    CASE
        WHEN EXTRACT(MONTH FROM calendar_date) IN (12, 1, 2)
            THEN 'Winter'
        WHEN EXTRACT(MONTH FROM calendar_date) IN (3, 4, 5)
            THEN 'Spring'
        WHEN EXTRACT(MONTH FROM calendar_date) IN (6, 7, 8)
            THEN 'Summer'
        ELSE 'Fall'
    END
FROM (
    -- Taxi pickup times
    SELECT
        tpep_pickup_datetime::DATE AS calendar_date,
        EXTRACT(HOUR FROM tpep_pickup_datetime)::INTEGER AS trip_hour
    FROM taxi_staging
    WHERE tpep_pickup_datetime IS NOT NULL

    UNION

    -- Taxi drop-off times
    SELECT
        tpep_dropoff_datetime::DATE,
        EXTRACT(HOUR FROM tpep_dropoff_datetime)::INTEGER
    FROM taxi_staging
    WHERE tpep_dropoff_datetime IS NOT NULL

    UNION

    -- Bike start times
    SELECT
        started_at::TIMESTAMP::DATE,
        EXTRACT(HOUR FROM started_at::TIMESTAMP)::INTEGER
    FROM bike_staging
    WHERE started_at IS NOT NULL

    UNION

    -- Bike end times
    SELECT
        ended_at::TIMESTAMP::DATE,
        EXTRACT(HOUR FROM ended_at::TIMESTAMP)::INTEGER
    FROM bike_staging
    WHERE ended_at IS NOT NULL
) AS all_times;

SELECT * FROM time_dimension;


-- Check for duplicate date/hour combinations (should be none).

SELECT
    date,
    hour,
    COUNT(*)
FROM time_dimension
GROUP BY date, hour
HAVING COUNT(*) > 1;


-- =====================================================
-- 20. PREPARE SOURCE TABLES
-- Sections 20-27 load TRIP and its subtypes. TRIP's generated
-- trip_id must be linked back to the staging row it came from,
-- so that the matching TAXI or BIKE row receives the same id.
--
-- Each staging row is first given a deterministic surrogate
-- source_key with ROW_NUMBER():
--   taxi : ordered by pickup/drop-off time, locations, distance
--          (taxi data has no natural trip identifier)
--   bike : ordered by ride_id
-- These are TEMP tables and disappear at the end of the session.
-- =====================================================

CREATE TEMP TABLE taxi_source AS
SELECT
    ROW_NUMBER() OVER (
        ORDER BY
            tpep_pickup_datetime,
            tpep_dropoff_datetime,
            "PULocationID",
            "DOLocationID",
            trip_distance
    ) AS source_key,
    *
FROM taxi_staging;


CREATE TEMP TABLE bike_source AS
SELECT
    ROW_NUMBER() OVER (ORDER BY ride_id) AS source_key,
    *
FROM bike_staging;


-- =====================================================
-- 21. PREPARE TRIP RECORDS
-- Assign trip IDs before inserting into TRIP.
-- trip_load_final generates the trip_id for every taxi and bike
-- trip (taxi first, then bike) and records which source row each
-- id came from.
-- =====================================================

CREATE TEMP TABLE trip_load_final (
    trip_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_key BIGINT NOT NULL,
    mode VARCHAR(10) NOT NULL,
    distance DOUBLE PRECISION,
    start_time_id BIGINT,
    end_time_id BIGINT,
    duration DOUBLE PRECISION
);


-- =====================================================
-- 22. PREPARE TAXI TRIPS
-- Looks up the start and end time_id for each taxi trip and
-- computes duration in seconds (EXTRACT(EPOCH ...)).
-- =====================================================

INSERT INTO trip_load_final (
    source_key,
    mode,
    distance,
    start_time_id,
    end_time_id,
    duration
)
SELECT
    t.source_key,
    'taxi',
    t.trip_distance,
    start_time.time_id,
    end_time.time_id,
    EXTRACT(EPOCH FROM (
        t.tpep_dropoff_datetime - t.tpep_pickup_datetime
    ))
FROM taxi_source t
LEFT JOIN time_dimension start_time
    ON start_time.date = t.tpep_pickup_datetime::DATE
   AND start_time.hour =
       EXTRACT(HOUR FROM t.tpep_pickup_datetime)::INTEGER
LEFT JOIN time_dimension end_time
    ON end_time.date = t.tpep_dropoff_datetime::DATE
   AND end_time.hour =
       EXTRACT(HOUR FROM t.tpep_dropoff_datetime)::INTEGER;


-- =====================================================
-- 23. PREPARE BIKE TRIPS
-- Same as Section 22. Distance is NULL because Citi Bike does
-- not report trip distance.
-- =====================================================

INSERT INTO trip_load_final (
    source_key,
    mode,
    distance,
    start_time_id,
    end_time_id,
    duration
)
SELECT
    b.source_key,
    'bike',
    NULL,
    start_time.time_id,
    end_time.time_id,
    EXTRACT(EPOCH FROM (
        b.ended_at::TIMESTAMP - b.started_at::TIMESTAMP
    ))
FROM bike_source b
LEFT JOIN time_dimension start_time
    ON start_time.date = b.started_at::TIMESTAMP::DATE
   AND start_time.hour =
       EXTRACT(HOUR FROM b.started_at::TIMESTAMP)::INTEGER
LEFT JOIN time_dimension end_time
    ON end_time.date = b.ended_at::TIMESTAMP::DATE
   AND end_time.hour =
       EXTRACT(HOUR FROM b.ended_at::TIMESTAMP)::INTEGER;


-- =====================================================
-- 24. PRESERVE SOURCE-TO-TRIP MAPPING
-- (trip_id, mode, source_key) lookup used to populate TAXI and
-- BIKE in Sections 26-27.
-- =====================================================

CREATE TEMP TABLE trip_source_mapping AS
SELECT
    trip_id,
    mode,
    source_key
FROM trip_load_final;


-- =====================================================
-- 25. INSERT INTO TRIP
-- OVERRIDING SYSTEM VALUE lets the pre-assigned trip_ids be
-- inserted into the GENERATED ALWAYS identity column.
-- =====================================================

INSERT INTO trip (
    trip_id,
    distance,
    start_time_id,
    end_time_id,
    mode,
    duration
)
OVERRIDING SYSTEM VALUE
SELECT
    trip_id,
    distance,
    start_time_id,
    end_time_id,
    mode,
    duration
FROM trip_load_final;


-- Synchronize the TRIP identity sequence.
-- Because ids were inserted explicitly, the sequence is moved to
-- MAX(trip_id) so that any future insert gets the next free id.

SELECT setval(
    pg_get_serial_sequence('trip', 'trip_id'),
    COALESCE((SELECT MAX(trip_id) FROM trip), 1),
    EXISTS (SELECT 1 FROM trip)
);


-- Verify trip counts (expected: 120,000 per mode; 240,000 total).

SELECT
    mode,
    COUNT(*) AS trip_count
FROM trip
GROUP BY mode
ORDER BY mode;

SELECT COUNT(*) AS total_trips
FROM trip;


-- =====================================================
-- 26. POPULATE TAXI
-- Joins each taxi staging row to its trip_id through the mapping.
-- source_month ('YYYY-MM') is converted to the first day of that
-- month.
-- =====================================================

INSERT INTO taxi (
    trip_id,
    start_location_id,
    end_location_id,
    total_amount,
    congestion_surcharge,
    source_month
)
SELECT
    mapping.trip_id,
    t."PULocationID",
    t."DOLocationID",
    t.total_amount,
    t.congestion_surcharge,
    (t.source_month || '-01')::DATE
FROM taxi_source t
JOIN trip_source_mapping mapping
    ON mapping.source_key = t.source_key
   AND mapping.mode = 'taxi';

SELECT * FROM taxi;


-- =====================================================
-- 27. POPULATE BIKE
-- Same approach as Section 26, also resolving member_casual to
-- its user_type_id.
-- =====================================================

INSERT INTO bike (
    trip_id,
    ride_id,
    start_station_id,
    end_station_id,
    user_type_id,
    source_month
)
SELECT
    mapping.trip_id,
    b.ride_id,
    b.start_station_id,
    b.end_station_id,
    ut.user_type_id,
    (b.source_month || '-01')::DATE
FROM bike_source b
JOIN trip_source_mapping mapping
    ON mapping.source_key = b.source_key
   AND mapping.mode = 'bike'
JOIN user_type ut
    ON ut.is_subscriber =
       CASE
           WHEN b.member_casual = 'member' THEN TRUE
           WHEN b.member_casual = 'casual' THEN FALSE
       END;

SELECT * FROM bike;


-- =====================================================
-- 28. POPULATE WIDE FEATURE TABLE
-- Copies the five features of each trip's start time from
-- TIME_DIMENSION into TRIP_FEATURE_WIDE (one row per trip).
-- This must occur AFTER trip records are populated.
-- ON CONFLICT makes the insertion safe to repeat.
-- =====================================================

INSERT INTO trip_feature_wide (
    trip_id,
    hour,
    day_of_week,
    is_weekend,
    month,
    season
)
SELECT
    t.trip_id,
    td.hour,
    td.day_of_week,
    td.is_weekend,
    td.month,
    td.season
FROM trip t
JOIN time_dimension td
    ON t.start_time_id = td.time_id
ON CONFLICT (trip_id) DO UPDATE SET
    hour = EXCLUDED.hour,
    day_of_week = EXCLUDED.day_of_week,
    is_weekend = EXCLUDED.is_weekend,
    month = EXCLUDED.month,
    season = EXCLUDED.season;


-- Validate wide feature table (expected: 240,000 rows, all unique).

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT trip_id) AS unique_trips
FROM trip_feature_wide;


-- =====================================================
-- 29. TRIP ANALYTICS VIEW
-- Joins TRIP with its start time, subtype details, stations and
-- user type into one row per trip, so the analytical queries
-- below do not repeat these joins. LEFT JOINs keep every trip:
-- bike columns are NULL for taxi trips and vice versa.
-- =====================================================

CREATE OR REPLACE VIEW trip_analytics AS
SELECT
    -- Trip (shared attributes)
    t.trip_id,
    t.mode,
    t.duration,
    t.distance,

    -- Start time
    start_time.date AS trip_date,
    start_time.year,
    start_time.month,
    start_time.day_of_week,
    start_time.hour,
    start_time.is_weekend,
    start_time.season,

    -- Bike only
    b.ride_id,
    b.start_station_id,
    start_station.name AS start_station_name,
    b.end_station_id,
    end_station.name AS end_station_name,
    ut.is_subscriber,

    -- Taxi only
    tx.start_location_id,
    tx.end_location_id,
    tx.total_amount,
    tx.congestion_surcharge,

    -- Source month from whichever subtype applies
    COALESCE(b.source_month, tx.source_month) AS source_month

FROM trip t
LEFT JOIN time_dimension start_time
    ON t.start_time_id = start_time.time_id
LEFT JOIN bike b
    ON t.trip_id = b.trip_id
LEFT JOIN taxi tx
    ON t.trip_id = tx.trip_id
LEFT JOIN station start_station
    ON b.start_station_id = start_station.station_id
LEFT JOIN station end_station
    ON b.end_station_id = end_station.station_id
LEFT JOIN user_type ut
    ON b.user_type_id = ut.user_type_id;


SELECT *
FROM trip_analytics
LIMIT 10;


-- =====================================================
-- INDEX BENCHMARKS (Sections 30-34)
-- For Queries 1, 2 and 5, EXPLAIN (ANALYZE, BUFFERS) records the
-- query plan and execution time before an index is created. The
-- EXPLAIN was then rerun after the index to compare plans.
-- Saved plans (Project folder):
--   Query1BeforeIndex / Query1AfterIndex   idx_trip_mode
--   Query2BeforeIndex / Query2AfterIndex   idx_trip_mode_start_time
--   Query5BeforeIndex / Query5AfterIndex   idx_trip_mode_distance
-- =====================================================


-- =====================================================
-- 30. ANALYTICAL QUERY 1
-- Average biking duration: weekends vs. weekdays.
-- =====================================================

SELECT
    CASE
        WHEN is_weekend THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'bike'
GROUP BY is_weekend
ORDER BY is_weekend;


-- Query plan before indexing (Query1BeforeIndex).

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    CASE
        WHEN is_weekend THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'bike'
GROUP BY is_weekend
ORDER BY is_weekend;


-- Index on trip mode, which every analytical query filters on.
-- ANALYZE refreshes planner statistics so the new index is
-- considered.

CREATE INDEX idx_trip_mode
ON trip (mode);

ANALYZE trip;


-- =====================================================
-- 31. ANALYTICAL QUERY 2
-- Weekend vs. weekday duration by rider type.
-- =====================================================

SELECT
    CASE
        WHEN is_weekend THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type,
    is_subscriber,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'bike'
GROUP BY is_weekend, is_subscriber
ORDER BY is_weekend, is_subscriber;


-- Query plan before the composite index (Query2BeforeIndex).

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    CASE
        WHEN is_weekend THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type,
    is_subscriber,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'bike'
GROUP BY is_weekend, is_subscriber
ORDER BY is_weekend, is_subscriber;


-- Composite index: filter on mode, then join to time_dimension
-- through start_time_id.

CREATE INDEX idx_trip_mode_start_time
ON trip (mode, start_time_id);

ANALYZE trip;


-- =====================================================
-- 32. ANALYTICAL QUERY 3
-- Weekend vs. weekday duration by hour.
-- =====================================================

SELECT
    CASE
        WHEN is_weekend THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type,
    hour,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'bike'
GROUP BY is_weekend, hour
ORDER BY hour, is_weekend;


-- =====================================================
-- 33. ANALYTICAL QUERY 4
-- Average taxi duration: weekends vs. weekdays.
-- =====================================================

SELECT
    CASE
        WHEN is_weekend THEN 'Weekend'
        ELSE 'Weekday'
    END AS day_type,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'taxi'
GROUP BY is_weekend
ORDER BY is_weekend;


-- =====================================================
-- 34. ANALYTICAL QUERY 5
-- Weekday taxi trips of similar distance:
-- Rush hour vs. non-rush hour.
-- Distances are grouped into 5-mile bands. Rush hour is
-- 6-9 AM and 3-6 PM (hours 6-9 and 15-18). Trips over 20 miles,
-- non-positive distances or durations, and bands with fewer
-- than 100 trips are excluded.
-- =====================================================

SELECT
    CONCAT(
        FLOOR(distance / 5) * 5,
        '-',
        FLOOR(distance / 5) * 5 + 5,
        ' miles'
    ) AS distance_range,
    CASE
        WHEN hour BETWEEN 6 AND 9
          OR hour BETWEEN 15 AND 18
        THEN 'Rush Hour'
        ELSE 'Non-Rush Hour'
    END AS time_period,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'taxi'
  AND is_weekend = FALSE
  AND distance IS NOT NULL
  AND distance > 0
  AND distance < 20
  AND duration > 0
GROUP BY
    FLOOR(distance / 5),
    CASE
        WHEN hour BETWEEN 6 AND 9
          OR hour BETWEEN 15 AND 18
        THEN 'Rush Hour'
        ELSE 'Non-Rush Hour'
    END
HAVING COUNT(*) >= 100
ORDER BY FLOOR(distance / 5), time_period;


-- Remove earlier indexes for the index comparison, so the
-- baseline plan below uses no index on TRIP.

DROP INDEX IF EXISTS idx_trip_mode;
DROP INDEX IF EXISTS idx_trip_mode_start_time;


-- Query plan before indexing (Query5BeforeIndex).

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    CONCAT(
        FLOOR(distance / 5) * 5,
        '-',
        FLOOR(distance / 5) * 5 + 5,
        ' miles'
    ) AS distance_range,
    CASE
        WHEN hour BETWEEN 6 AND 9
          OR hour BETWEEN 15 AND 18
        THEN 'Rush Hour'
        ELSE 'Non-Rush Hour'
    END AS time_period,
    ROUND((AVG(duration) / 60)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'taxi'
  AND is_weekend = FALSE
  AND distance IS NOT NULL
  AND distance > 0
  AND distance < 20
  AND duration > 0
GROUP BY
    FLOOR(distance / 5),
    CASE
        WHEN hour BETWEEN 6 AND 9
          OR hour BETWEEN 15 AND 18
        THEN 'Rush Hour'
        ELSE 'Non-Rush Hour'
    END
HAVING COUNT(*) >= 100
ORDER BY FLOOR(distance / 5), time_period;


-- Composite index supporting the mode filter and the distance
-- range condition. This is the only index on TRIP left in place
-- at the end of the script.

CREATE INDEX idx_trip_mode_distance
ON trip (mode, distance);

ANALYZE trip;


-- =====================================================
-- 35. ANALYTICAL QUERY 6
-- Busiest Citi Bike stations.
-- UNION ALL stacks departures and arrivals so that each station
-- is counted once for every trip that starts or ends there.
-- Returns the top 10 by total activity.
-- =====================================================

SELECT
    station_id,
    station_name,
    COUNT(*) AS total_station_activity,
    SUM(CASE WHEN station_type = 'Start' THEN 1 ELSE 0 END)
        AS total_departures,
    SUM(CASE WHEN station_type = 'End' THEN 1 ELSE 0 END)
        AS total_arrivals
FROM (
    SELECT
        start_station_id AS station_id,
        start_station_name AS station_name,
        'Start' AS station_type
    FROM trip_analytics
    WHERE mode = 'bike'
      AND start_station_id IS NOT NULL

    UNION ALL

    SELECT
        end_station_id AS station_id,
        end_station_name AS station_name,
        'End' AS station_type
    FROM trip_analytics
    WHERE mode = 'bike'
      AND end_station_id IS NOT NULL
) AS station_activity
GROUP BY station_id, station_name
ORDER BY total_station_activity DESC
LIMIT 10;


-- =====================================================
-- 36. ANALYTICAL QUERY 7
-- Average taxi fare by distance and rush hour.
-- Same 5-mile bands and rush-hour definition as Query 5,
-- covering all days and distances under 25 miles.
-- =====================================================

SELECT
    CONCAT(
        FLOOR(distance / 5) * 5,
        '-',
        FLOOR(distance / 5) * 5 + 5,
        ' miles'
    ) AS distance_band,
    CASE
        WHEN hour BETWEEN 6 AND 9
          OR hour BETWEEN 15 AND 18
        THEN 'Rush Hour'
        ELSE 'Non-Rush Hour'
    END AS time_period,
    ROUND(AVG(total_amount)::NUMERIC, 2) AS average_fare,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE mode = 'taxi'
  AND distance IS NOT NULL
  AND distance > 0
  AND distance < 25
  AND total_amount IS NOT NULL
  AND total_amount > 0
GROUP BY
    FLOOR(distance / 5),
    CASE
        WHEN hour BETWEEN 6 AND 9
          OR hour BETWEEN 15 AND 18
        THEN 'Rush Hour'
        ELSE 'Non-Rush Hour'
    END
HAVING COUNT(*) >= 100
ORDER BY FLOOR(distance / 5), time_period;


-- =====================================================
-- 37. ANALYTICAL QUERY 8
-- Average duration by mode and pickup hour.
-- =====================================================

SELECT
    mode AS transportation_mode,
    hour AS pickup_hour,
    ROUND((AVG(duration) / 60.0)::NUMERIC, 2)
        AS average_duration_minutes,
    COUNT(*) AS total_trips
FROM trip_analytics
WHERE duration > 0
GROUP BY mode, hour
ORDER BY hour, mode;


-- =====================================================
-- 38. VERIFY ANALYTICAL VIEW
-- Confirms the view contains both modes, then lists the indexes
-- currently defined on TRIP.
-- =====================================================

SELECT
    mode,
    COUNT(*) AS total_trips
FROM trip_analytics
GROUP BY mode
ORDER BY mode;


SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'trip';


-- =====================================================
-- 39. POPULATE NORMALIZED FEATURE TABLE
-- Registers the five model features in FEATURE, then fills
-- TRIP_FEATURE with one row per trip per feature.
-- =====================================================

INSERT INTO feature (
    feature_name,
    feature_type,
    description
)
VALUES
    ('hour', 'numeric',
     'Hour of the day when the trip started (0-23)'),
    ('day_of_week', 'categorical',
     'Day of the week when the trip started'),
    ('is_weekend', 'boolean',
     'Whether the trip started on a weekend'),
    ('month', 'numeric',
     'Month when the trip started (1-12)'),
    ('season', 'categorical',
     'Season when the trip started');


SELECT *
FROM feature
ORDER BY feature_id;


-- Populate one row per trip-feature combination.
-- CROSS JOIN pairs every trip with all five features; the CASE
-- picks the matching time_dimension value and casts it to TEXT.
-- Expected: 240,000 trips x 5 features = 1,200,000 rows.

INSERT INTO trip_feature (
    trip_id,
    feature_id,
    feature_value
)
SELECT
    t.trip_id,
    f.feature_id,
    CASE f.feature_name
        WHEN 'hour' THEN td.hour::TEXT
        WHEN 'day_of_week' THEN td.day_of_week::TEXT
        WHEN 'is_weekend' THEN td.is_weekend::TEXT
        WHEN 'month' THEN td.month::TEXT
        WHEN 'season' THEN td.season::TEXT
    END AS feature_value
FROM trip t
JOIN time_dimension td
    ON t.start_time_id = td.time_id
CROSS JOIN feature f
WHERE f.feature_name IN (
    'hour',
    'day_of_week',
    'is_weekend',
    'month',
    'season'
);


-- Validate normalized feature store.

SELECT COUNT(*) AS total_feature_records
FROM trip_feature;


-- Sample of the row-oriented format (5 rows per trip).

SELECT
    tf.trip_id,
    f.feature_name,
    tf.feature_value
FROM trip_feature tf
JOIN feature f
    ON tf.feature_id = f.feature_id
ORDER BY tf.trip_id, f.feature_id
LIMIT 25;


-- =====================================================
-- 40. FINAL VALIDATION
-- Row counts for every permanent table. Expected after a fresh
-- build: trip 240,000; taxi 120,000; bike 120,000;
-- trip_feature 1,200,000; trip_feature_wide 240,000; feature 5;
-- prediction and prediction_feature 0 (filled by the notebook).
-- =====================================================

SELECT 'trip' AS table_name, COUNT(*) AS row_count
FROM trip

UNION ALL

SELECT 'taxi', COUNT(*) FROM taxi

UNION ALL

SELECT 'bike', COUNT(*) FROM bike

UNION ALL

SELECT 'trip_feature', COUNT(*) FROM trip_feature

UNION ALL

SELECT 'trip_feature_wide', COUNT(*) FROM trip_feature_wide

UNION ALL

SELECT 'feature', COUNT(*) FROM feature

UNION ALL

SELECT 'prediction', COUNT(*) FROM prediction

UNION ALL

SELECT 'prediction_feature', COUNT(*) FROM prediction_feature

UNION ALL

SELECT 'prediction_audit', COUNT(*) FROM prediction_audit;


-- Verify that the wide feature store has exactly one row per
-- trip (total_wide_rows = unique_trips).

SELECT
    COUNT(*) AS total_wide_rows,
    COUNT(DISTINCT trip_id) AS unique_trips
FROM trip_feature_wide;


-- Verify that the normalized feature store has five
-- feature records per trip
-- (total_normalized_records = 5 x unique_trips).

SELECT
    COUNT(*) AS total_normalized_records,
    COUNT(DISTINCT trip_id) AS unique_trips
FROM trip_feature;


-- =====================================================
-- END OF DATABASE BUILD SCRIPT
-- =====================================================
