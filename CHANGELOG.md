# Changelog

All notable changes to Allsky-ML-Curator. Format follows
[Keep a Changelog](https://keepachangelog.com/) loosely — one section
per released `MARKETING_VERSION` in `project.yml`.

## [0.4.0] — 2026-04-19

Triage wave. The MVP workflow now supports *curating the library*
alongside rating it: remove wrong frames, scan metadata in a list
view, pull targeted batches by sky-temperature, inspect single
frames with full metadata side-by-side.

### Added
- **Remove images** — `Delete` / `⌘⌫` via a proper Edit menu command,
  plus a per-tile / per-row **context menu** "Delete N highlighted
  image(s)". Modern `.alert(_:isPresented:)` confirmation. Removal
  cascades to `labels` + `predictions` (FK) and purges the
  HEIC + Vision `.fp` sidecars. Supabase rows stay (upsert by
  `image_path` on re-ingest).
- **List view toggle** alongside the matrix. Filename, capture UTC,
  camera, rating stars, ingest timestamp, prediction, R / T flags.
  Same selection model as the matrix so ⌘⌫ / rating keys work
  identically.
- **Weather-filtered ingest** (`⌘⇧I`). Picks a sky-temperature range
  + date window + camera, queries Supabase `cloudwatcher_readings`,
  resolves URLs to local paths with `/volume1/` → `/Volumes/`
  remapping, dedups against the local index, previews count +
  sample filenames, and ingests only the new rows on confirm.
- **Single-frame details in the right sidebar.** When exactly one
  tile is selected the panel shows filename + "reveal in Finder"
  button + Copy-to-clipboard button, captured / added timestamps,
  camera, sun + moon ephemeris, weather context (cloudwatcher sky
  temp, meteoblue cloud % / seeing), sensor sidecar (exposure /
  gain / sensor temp), reflection + transitional risk. Every value
  row is `.textSelection(.enabled)` so individual fields can be
  copied.
- **Selection count chip** ("N of M selected") in the bottom legend
  bar so the curator always knows how many tiles a rating keystroke
  will hit.
- **Rebuild missing thumbnails** action in Preferences → Advanced:
  walks every image row, checks whether the HEIC exists under the
  current camera geometry + crop cacheKey, regenerates the missing
  ones in the throttled pipeline. Fixes the "chunk gap" pattern
  that appears when fisheye / crop settings change without
  purging the whole cache.
- **Sandbox bookmark persistence**. NSOpenPanel URLs are now
  archived with `.withSecurityScope` bookmarkData in UserDefaults
  and re-activated on every `applicationDidFinishLaunching`, so
  `/Volumes/AllSky-Rheine/...` stays readable across app
  relaunches. Preferences → Advanced gains a "Grant folder
  access" button for re-authorising without going through ingest.
- **Launch-time database repairs** (all idempotent, no-op on a
  clean DB):
  - `/volume1/...` → `/Volumes/...` path prefix rewrite (fixes
    rows from the first weather-ingest run before the remap
    landed).
  - `cameraSource` ↔ path-pattern consistency for the Rheine
    rig (`/zwo/` = color, rest = mono).
  - Back-fill `reflectionRiskScore` for daytime color-camera rows
    that were scored 0 under the pre-fix "handled elsewhere"
    daylight formula.

### Changed
- **Selection model overhaul (final).** Classical Finder / Excel:
  plain arrow / page / home / end moves both cursor and anchor
  onto the new tile, selection collapses to `{cursor}`, so the
  next Shift action always extends from wherever the cursor
  currently sits — no pre-click required. Shift+arrow /
  Shift+click / Shift+page / Shift+home / Shift+end extends with
  the single linear range `linearRange(anchorIndex, cursorIndex)`
  (row-major, inclusive). Same rule for horizontal and vertical;
  the row-aligned-rectangle and single-cell-shift-horizontal
  special cases are gone. Cursor + anchor are tracked as item
  IDs so list changes preserve the highlighted tile by identity.
- **Reflection-risk formula** for day-capable cameras: peaks at
  sun ≈ 30° altitude (strongest specular angle off the plexiglass
  dome), floor of 0.7 across the daylight band, linear ramp
  through twilight to 0 at −12° sun altitude.
- **Meteoblue `hasForecast` gating.** The aux-feature flag now
  requires all three meteoblue fields (hour_id + totalcloud +
  seeing) to be present, not just hour_id, so rows upgraded from
  v4 (NULL values after the v5 migration) no longer inject a
  fabricated clear-sky / perfect-seeing signal into training.
- **Classifier chip** shows 5-fold CV accuracy when available,
  falling back to train accuracy only for datasets too small for
  CV. Restored classifiers rehydrate `trainAccuracy` +
  `durationSeconds` from a JSON `notes` column so the side panel
  stops showing `0%` after relaunch.
- **Persisted model version IDs** include a millisecond counter so
  two consecutive trains in the same second don't collide on the
  `model_versions` primary key (previously the collision was
  silently swallowed and a restore could load the stale snapshot).

### Fixed
- **Ingest cancellation no longer drops a staged batch.** A `defer`
  in `ingestFolder` / `ingestFiles` guarantees the final
  `pendingBatch` reaches the DB on every exit path.
- **`flushPendingBatch` keeps the batch intact on error** so a
  retry path can pick it up instead of losing up to 499
  transiently-failed rows.
- **Auto-rate never overwrites a human rating.** `setAutoRating`
  refuses to demote a `source == .human` label even if the stream
  had queued a write for that frame earlier.
- **Detached prediction recompute race.** `recomputeAllPredictions`
  snapshots a monotonic `weightsVersion` before going detached and
  drops its result if a newer train / restore replaced the weights
  in the meantime — stale predictions can't overwrite newer ones.
- **Shared pipeline task cancellation.** `EmbeddingPipeline.generate`
  and `ThumbnailCache.generate` no longer call `task.cancel()` on
  the shared inflight task. A single joiner scrolling off can't
  rob every other joiner (warmer, auto-rater, other tiles) of
  the result.
- **Confidence prefix Q / C on InspectionView** now ignores the
  keystroke when `.command` is held, so `⌘Q` / `⌘C` pass through.

## [0.3.0] — 2026-04-18

The MVP-usable wave. A curator can now rate, retrain, auto-rate,
inspect, and trust the classifier across relaunches without losing
state.

### Added
- **Autonomous streaming auto-rate** (`⌘⇧A`). Commits `source='auto'`
  labels one at a time with live progress, animates ratings into the
  grid in small batches, supports mid-run cancel. Gated behind a
  configurable minimum of human labels (default 200) with a live slider
  in Preferences → Training. (#27, #32)
- **Classifier persistence** across launches via `model_versions`
  table. Every successful `train()` writes a CMLW-v1 weights blob
  carrying featureDim, weights and bias; `restoreLatestModel()` is
  invoked from a new launch-time `.task` so prediction overlays are
  warm before the user lifts a finger. FeatureDim mismatch (e.g. after
  a migration that grows the aux vector) falls back to "untrained"
  silently. (#25)
- **Content SHA-256 hash** upgrade during embedding extraction. The
  pipeline reads the JPEG bytes once, feeds both the hash and the
  ImageIO source, and writes the real content hash onto the image row
  — replacing the path-identity seed. Previously-synced labels for
  that image are marked unsynced so the next Supabase push catches
  up. (#26)
- **Meteoblue forecast aux features**. Ingest now fetches the matching
  `meteoblue_hourly` window (±30 min) alongside cloudwatcher, stores
  `meteoblueHourId` + denormalised `totalcloud` + `seeing_arcsec` on
  the image row, and the classifier aux vector grows from 779 to 782
  slots (`mb_has_forecast`, `mb_total_cloud_norm`, `mb_seeing_norm`).
  SyncEngine forwards `meteoblue_hour_id` to
  `ml_training_samples` (previously hardcoded null). (#30, #31)
- **Single-image inspection sheet** opened from the matrix with Enter:
  full JPEG + metadata sidebar (time, ephemeris, sensor sidecar,
  rating, prediction probability bar chart). Arrow keys step through
  the filtered list, digits / R / T apply ratings without leaving the
  sheet. (#29)
- **Cloud motion detection** via Vision
  `VNTranslationalImageRegistrationRequest` between a frame and its
  nearest same-camera predecessor. Reports degrees-per-minute of sky
  angle plus a frame-local bearing; if the camera has a non-zero
  `northOffsetDeg` calibrated in Preferences → Camera, projects to a
  compass bearing (N / NE / E / … / NW). Rendered as a rotated arrow
  in the inspection sidebar. (#34, #35)
- **Preferences → Training tab** with sliders for learning rate,
  iterations, L2 regularisation, clear-sky class boost, autonomous
  confidence threshold, and minimum human-labels gate. `ClassifierEngine`
  reads hyperparameters from `AppSettings` at every `train()` call so
  edits take effect on the next ⌘T without a restart. Reset-to-defaults
  button wipes the relevant UserDefaults keys. (#28)
- **Confidence prefix keys**: `Q` arms "quick" (confidence=1) and `C`
  arms "certain" (confidence=3) for the next digit press. Layout-agnostic
  single-character matches — avoids the layout hostility of Shift+digit
  / Option+digit on non-US keyboards. Mirrored in MatrixView +
  InspectionView; a floating HUD announces the armed state; Esc
  cancels. (#33)
- **Per-camera north-offset calibration** (`colorNorthOffsetDeg`,
  `monoNorthOffsetDeg`) stored in AppSettings with fields in
  Preferences → Camera → Compass alignment. Feeds the cloud-motion
  compass bearing. (#34)
- **Release pipeline helper** at `scripts/release.sh` wraps xcodegen →
  xcodebuild archive → exportArchive (developer-id) → ditto-zip →
  notarytool submit → stapler staple → final zip → `gh release create
  --latest`. `--skip-notarize` / `--skip-gh` flags support local
  signed builds. README documents the one-time
  `xcrun notarytool store-credentials` bootstrap. (#36)

### Changed
- **Selection model rewrite to classical Finder / Excel semantics**.
  Plain arrow / page / Home / End nav now collapses to a single tile
  *and* advances the anchor; Shift+arrow extends from the stable anchor.
  Shift+Up/Down/PageUp/PageDown/Home/End fill full rows; Shift+Left/
  Right mutates selection by exactly one tile (insert on move-away,
  remove on move-back) so a multi-row block built with Shift+Down
  survives horizontal trimming. (#23, #24)

### Fixed
- The autonomous rater can no longer double-label a frame: a
  subsequent human `setRating` demotes the prior auto label to
  `isCurrent=false` before inserting the new row. The auto flow uses
  a dedicated `ImageLibrary.setAutoRating` path so the gating logic
  stays isolated from manual ratings. (#27)

### Scope decisions (explicit)
- FITS v1.1 support — dropped.
- Obstruction-mask editor — dropped; dynamic zenith crop covers the
  need.
- Manual cardinal-quadrant cloud annotation — rejected; automatic
  cloud motion detection ships instead.
- Multi-site rework — deferred until a second observatory goes
  online.
- CloudWatcher Solo threshold feedback job — deferred.

---

## [0.2.0] — earlier 2026-04-18

Initial ingest, matrix view, rating flow, embeddings, classifier,
info side panel, zenith crop, 5-fold CV + per-class metrics. See the
pre-0.3 commit history and closed PRs #1 – #22 for the per-feature
breakdown.
