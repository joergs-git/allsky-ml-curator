-- =============================================================================
-- Allsky-ML-Curator schema additions
-- Target: the EXISTING astro-weather Supabase project
-- (do NOT create a new Supabase project for this).
--
-- Prerequisites (already present from astro-weather):
--   - cloudwatcher_readings (id BIGSERIAL, timestamp TIMESTAMPTZ, ...)
--   - meteoblue_hourly      (id BIGSERIAL, timestamp TIMESTAMPTZ, ...)
--
-- Apply via Supabase SQL editor or psql. Safe to re-run (IF NOT EXISTS).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ml_training_samples
--   Ground-truth labels produced by the macOS curator (one active row
--   per image; history kept client-side, server keeps the most recent).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ml_training_samples (
    id                        BIGSERIAL PRIMARY KEY,

    -- Identity
    image_path                TEXT        NOT NULL UNIQUE,
    image_hash_sha256         TEXT,
    camera_source             TEXT        NOT NULL,
    camera_profile_id         TEXT,

    -- Time
    capture_utc               TIMESTAMPTZ NOT NULL,
    time_of_day               TEXT,

    -- Cross-references to astro-weather data
    cloudwatcher_reading_id   BIGINT      REFERENCES cloudwatcher_readings(id),
    meteoblue_hour_id         BIGINT      REFERENCES meteoblue_hourly(id),

    -- Ephemeris (pre-computed client-side)
    sun_alt_deg               REAL,
    sun_az_deg                REAL,
    moon_alt_deg              REAL,
    moon_az_deg               REAL,
    moon_phase                REAL,
    reflection_risk_score     REAL,

    -- Labels
    class                     SMALLINT    CHECK (class BETWEEN 0 AND 5),
    reflection_flag           SMALLINT    DEFAULT 0,
    transitional_flag         SMALLINT    DEFAULT 0,

    -- Provenance
    source                    TEXT        DEFAULT 'human'
                                          CHECK (source IN ('human','auto','auto_confirmed')),
    sample_weight             REAL        DEFAULT 1.0,
    confidence                SMALLINT,
    annotator_id              TEXT,
    labeled_at                TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ml_training_capture_utc
    ON ml_training_samples(capture_utc);
CREATE INDEX IF NOT EXISTS idx_ml_training_class
    ON ml_training_samples(class);
CREATE INDEX IF NOT EXISTS idx_ml_training_camera_source
    ON ml_training_samples(camera_source);

-- -----------------------------------------------------------------------------
-- ml_predictions
--   Model output for each (image, model_version). Used for offline evaluation,
--   shared baselines across machines, and downstream consumers (AstroTriage).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ml_predictions (
    id                    BIGSERIAL PRIMARY KEY,
    image_path            TEXT        NOT NULL,
    model_version         TEXT        NOT NULL,
    predicted_class       SMALLINT,
    class_probabilities   JSONB,
    reflection_prob       REAL,
    -- v2.0 cloud-motion output (NULL until the v2 feature lands)
    motion_vector_deg_per_min REAL,
    motion_azimuth_deg        REAL,
    created_at            TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (image_path, model_version)
);

CREATE INDEX IF NOT EXISTS idx_ml_predictions_model_version
    ON ml_predictions(model_version);

-- -----------------------------------------------------------------------------
-- ml_model_metadata
--   One row per trained model snapshot. Allows sharing models across machines
--   (e.g. via Supabase Storage for the binary weights) and computing the
--   current best version.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ml_model_metadata (
    version               TEXT PRIMARY KEY,
    trained_at            TIMESTAMPTZ NOT NULL,
    training_set_size     INTEGER,
    class_counts          JSONB,
    classifier_type       TEXT,          -- 'logreg' | 'mlp2' | ...
    accuracy              REAL,
    storage_path          TEXT,          -- optional Supabase Storage key for the weights blob
    notes                 TEXT
);

-- =============================================================================
-- Notes on RLS:
--   astro-weather runs without RLS on its existing tables (anon key on a
--   trusted LAN). These new tables follow the same posture for now; when
--   multi-user labelling arrives, add per-annotator policies here.
-- =============================================================================
