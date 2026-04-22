# Changelog

All notable changes to Allsky-ML-Curator. Format follows
[Keep a Changelog](https://keepachangelog.com/) loosely — one section
per released `MARKETING_VERSION` in `project.yml`.

## [0.5.6] — 2026-04-22

Gives the MLP explicit moon- and sun-visibility interaction
features so it can learn "bright moon high up → expect sky glow,
not cloud" without first having to discover the `phase × sin(alt)`
interaction from 4 separate scalars.

### Added
- **Two new aux features at the tail of the feature vector**:
  * `moon_visibility = moon_phase × max(0, sin(moon_alt))`
  * `sun_visibility  = max(0, sin(sun_alt))`
  Same formulas as the bottom-left tile icons, so the signal the
  curator *sees* on the tile matches what the model *gets as
  input*.
- **Feature vector grows 782 → 784**, `FeatureVectorBuilder.auxCount`
  14 → 16.

### Why this should help

The linear softmax head from 0.4.x could represent `a × b` as a
single weight on the interaction term. The MLP head (0.5.0
onwards) has to compose `a × b` through a ReLU layer, which at
~1.5k night-clear samples was demonstrably *not* being learned —
the 0.5.5 mismatch review showed bright-moon-on-clear-sky frames
being predicted as class 4 (thin cloud) or even class 1 (full
clouds). Precomputing the interaction short-circuits that.

### Required action

Existing trained classifier blobs (CMLW v2, 782-dim) are rejected
by `decodeWeights` because the featureDim no longer matches. The
app silently falls back to "untrained" on launch; the user hits
⌘T once to retrain on the new 784-dim vector. Takes ~5 s on the
Release build.

## [0.5.5] — 2026-04-22

Mirror of the night-only path for a future daytime classifier.

### Added
- **`AppSettings.dayOnlyMode: Bool`** plus
  **`dayOnlySunAltMinDeg: Double`** (default 10°, range −6…30°).
  Parallel to `nightOnlyMode`: when on, matrix + training keep only
  frames with `sun_alt_deg >= dayOnlySunAltMinDeg`.
- **`AppSettings.sunAltitudeProblemThresholdDeg: Double`** (default
  10°, range −6…45°). Gates the new sun-risk badge (SF Symbol
  `sun.max.fill`, warm orange capsule) in the tile bottom-left,
  mirror of the moon badge. Opacity scales with `sin(sun_alt)`.
- **Preferences → Training → Time-of-day filter** now has both
  toggles stacked with their own sliders. Flipping one on
  automatically flips the other off — the predicates compose to
  zero frames otherwise, so making them mutually exclusive in the
  UI is clearer than letting the user footgun.
- **Preferences → Training → Overlay thresholds** extended with a
  second slider for the sun altitude badge, sibling of the moon
  slider.

### Changed
- `ImageLibrary.fetchImages` gains `minSunAltDeg: Double?` — same
  semantics as `maxSunAltDeg` but inverted. Applied in the same
  query pass; both can technically be active (UI prevents it).
- `ClassifierEngine.loadTrainingSet` filters on either or both
  bounds before building the sample set, so `totalRated` in the
  coverage diagnostic reflects whichever sub-window is active.

## [0.5.4] — 2026-04-22

Two new at-a-glance risk icons on every matrix tile (driven by
ingest-time ephemeris + geometry), a tunable moon-problem
threshold, a stop/restart toggle on the Embeddings chip, and a
fix for the broken-image placeholder in Inspection.

### Added
- **Moon-risk icon** (bottom-left, golden capsule with SF Symbol
  `moon.fill`). Shown when `moon_alt_deg ≥ threshold` AND the moon
  is not new. Opacity scales with `moon_phase × sin(moon_alt)` so
  a full moon at zenith is vivid, a half-moon near the threshold
  is faint. Tooltip: exact alt / phase / combined score.
- **Reflection-risk icon** (bottom-left, orange capsule with SF
  Symbol `sparkles`). Driven by the pre-computed
  `reflection_risk_score` on `ImageRecord` — distinct from the
  curator's own `R` label (bottom-right), which is a human
  judgement. Shown when the auto score > 0.2. Tooltip shows the
  exact percentage.
- **Preferences → Training → Overlay thresholds → Moon altitude
  problem** slider (0°…90°, default 30°). Below the threshold,
  moon-badges are hidden: 30° matches the Rheine site where the
  horizon mask + camera geometry suppresses anything lower. Raise
  for treed horizons, lower for exposed ones.
- **Embeddings chip is now a stop/start toggle.** Click while the
  warmer is idle or complete → starts a fresh pass. Click while it
  is running → cancels. Icon flips between `cpu` and `stop.fill`
  so the chip-state reinforces what the next click will do.
  Cancelling leaves already-written sidecars on disk; a subsequent
  re-run skips them via `sidecarExists` and resumes where it left
  off, so the cycle is lossless.

### Fixed
- **Inspection view now actually shows the full frame.**
  `NSImage(contentsOf:)` was being called synchronously on
  MainActor from the View body, which silently failed on SMB
  mounts even with a valid security-scoped bookmark in place. The
  image now loads via `CGImageSourceCreateWithURL` on a detached
  `userInitiated` task (same code path the `ThumbnailCache` uses
  — and was already working for tile thumbnails). A loading
  spinner shows during decode; a descriptive error with a
  Preferences-pointer shows if the decode fails.

## [0.5.3] — 2026-04-19

Adds a night-only filter so the classifier doesn't have to fight
the daytime feature space. After the 0.5.2 mismatch review it was
clear most class-1 ↔ class-5 confusion came from daytime frames —
bright overcast and bright clear sky look near-identical in Vision
FeaturePrint at sun_alt > 0°, and sun-reflection artefacts on the
color camera dominate whatever cloud signal remains. Filtering
day / twilight frames out of both the matrix and training lets the
model specialise on night, where the features actually separate.

### Added
- **`AppSettings.nightOnlyMode: Bool`** plus
  **`nightOnlySunAltMaxDeg: Double`** (default −18° = astronomical
  night, range −18…−6). When the mode is on, `fetchImages` and
  `ClassifierEngine.loadTrainingSet` both drop frames whose
  `sun_alt_deg > nightOnlySunAltMaxDeg`.
- **Preferences → Training → Time-of-day filter** — toggle + slider
  with standard-threshold legend (civil / nautical / astronomical).
- **`.nightOnlyFilterChanged` notification** so flipping the toggle
  in Preferences triggers an immediate matrix reload instead of
  waiting for the next user-initiated refresh.

### Soft by design
No rows are deleted or flipped to `is_excluded = 1`. The filter is
a query-time predicate on `sun_alt_deg`, fully reversible by
toggling Night-only off. This keeps the door open for a
**separate** day-classifier on the same dataset later, without a
re-ingest.

## [0.5.2] — 2026-04-19

Label-audit workflow. After the 0.5.0 MLP training converged on
36 % accuracy with class 1 stuck at 10 % recall, the next
diagnostic step is reviewing *which* frames the classifier
disagrees with — but there was no UI path short of opening
Inspection on every single rated tile. 0.5.2 surfaces
disagreements directly in the matrix.

### Added
- **Mismatch indicator on rated matrix tiles.** When the
  classifier's top pick differs from the human label, the tile
  gets a dashed orange inner border and a small warning badge
  in the top-right showing the predicted class number. The
  badge takes priority over the transitional (T) flag on the
  same corner; the underlying rating stars, tier colour, and
  reflection (R) flag are unaffected.
- **`RatingFilter.mismatches`** entry in the Filter picker
  ("Only mismatches (rating ≠ prediction)"). Selects every
  rated frame whose cached prediction disagrees with the
  human label. Post-fetch filter — predictions live in
  memory, not SQLite, so the DB query returns all rated rows
  and `ContentView.reload()` applies the mismatch predicate.
- **Auto-refresh on retrain** — watching
  `classifier.summary?.trainedAt`: if the filter is on
  `.mismatches` when `⌘T` finishes, the matrix re-applies the
  post-filter against the new predictions instead of staying
  stale against the old ones.

## [0.5.1] — 2026-04-19

UI stays responsive during `⌘T`. The 0.5.0 MLP refit is heavier
than the 0.4.x linear logreg (one extra matmul pair per iteration,
× 6 fits counting CV), and the whole GD loop was running
synchronously on the MainActor via an `@MainActor` instance
method. Result: the UI froze for a minute+ on the full 14.9k-label
set, pointer went beach-balled, the user couldn't tell whether the
app was still alive or deadlocked.

### Changed
- **Training math is now nonisolated.** All the Accelerate / vDSP
  helpers (`fitFullModel`, `runCrossValidation`,
  `runCrossValidationIfFeasible`, `computeSampleWeights`,
  `forwardMLP`, `forwardLinear`, `softmaxInPlace`,
  `applySampleWeights`, `multiply`, `crossEntropyLoss`) are
  `nonisolated static` and take the `Hyperparameters` +
  `numClasses` they need as explicit parameters, so they don't
  require MainActor.
- **`train()` dispatches to `Task.detached(priority: .userInitiated)`.**
  The detached task returns a `Sendable TrainingResult`; only the
  commit (assign weights to `self`, bump `weightsVersion`, write
  the summary) happens back on MainActor. `recomputeAllPredictions`
  + `persistTrainedModel` already awaited their own detached paths,
  so those stay unchanged.

### Removed
- `runGradientDescent` (collapsed into `fitFullModel` which now
  returns the final loss + training accuracy alongside the four
  parameter tensors). One source of truth for the MLP math.

## [0.5.0] — 2026-04-19

Replaces the linear logistic-regression classifier with a
**two-layer MLP** (Dense → ReLU → Dense → softmax). The linear
head hit a hard ceiling on Rheine's 14.9k-label dataset — train
accuracy stuck at ~30 % because the "full clouds at bright day" vs
"clear at bright day" boundary in Vision FeaturePrint space isn't
linearly separable, and no amount of class-boost tuning could move
it. One hidden ReLU layer gives the head enough capacity to learn
that cut.

### Added
- **`ClassifierEngine` MLP head.** `weights1` / `bias1` (featureDim
  × hiddenDim) + `weights2` / `bias2` (hiddenDim × numClasses).
  He-uniform init for both layers (deterministic xorshift seed per
  layer so CV accuracy is stable across re-trains on identical
  data). Full-batch softmax-cross-entropy GD with L2 on both weight
  matrices. Same Accelerate / vDSP stack as before — no new deps.
- **`Preferences → Training → Hidden layer units`** slider,
  16 … 512 step 16, default 128.
- **Persistence format v2 (`CMLW v2`).** Header grows to 20 bytes
  to carry `hiddenDim`. Encoder / decoder rewritten accordingly;
  the classifier-type column flips from `logreg` to `mlp2` on the
  next persisted row.

### Changed
- **Old `CMLW v1` model rows are silently rejected on restore** —
  v1 lacked the hidden layer entirely, so no sensible upgrade path
  exists. On first launch of 0.5.0 the toolbar chip shows
  "untrained"; hit ⌘T once to retrain with the MLP. The v1 row
  stays in `model_versions` for archaeology but isn't loaded.
- **Section title** in Preferences → Training renamed from
  "Logistic-regression head" to "MLP head (2 layers)".

### Removed
- `fitLinearClassifier`. CV now calls `fitMLP` which returns the
  four parameter tensors + hiddenDim; `argmaxPrediction` likewise
  runs the two-layer forward.

## [0.4.2] — 2026-04-19

Replaces the single `clearClassBoost` setting with a **per-class
boost vector**. The previous knob applied one multiplier to classes
4 + 5 together, which at the 14.9k-label mark collapsed class 1
(full clouds) to 3 % recall on Rheine's data — the boosted-but-
already-bright class 5 samples dominated the gradient and pulled
the linear decision boundary away from class 1. A per-class vector
lets the curator lift exactly the class that's under-recalled
without collateral damage to the others.

### Changed
- **Preferences → Training → Per-class boost.** Five sliders, one
  per RatingClass (1 full … 5 clear), range 0.1× … 5.0×. Default
  all 1.0× (pure inverse-frequency, perfectly balanced loss).
- **`ClassifierEngine.Hyperparameters.classBoosts: [Float]`**
  replaces the old `clearClassBoost: Float`. Weight computation at
  `ClassifierEngine.swift:510` now indexes per class instead of the
  `(c >= 3) ? boost : 1` ternary.
- **Migration** — reading the new `classWeightBoosts` on a stale
  install with the legacy `ml.clearClassBoost` key falls back to
  `[1, 1, 1, legacy, legacy]` so no retrain behaviour change across
  the 0.4.1 → 0.4.2 upgrade unless the user touches a slider.

## [0.4.1] — 2026-04-19

Fixes the "chip stuck at X / Y" symptom where the Embeddings gauge
sat at a fraction of the rated total for the rest of the session
after a heavy rating burst. Root cause: the embedding warmer was
wired into the root view's `.task { }` modifier, which runs exactly
once at launch and snapshots the rated-image list before the user
starts working. Any frames rated *during* the session stayed
unembedded, the classifier trained on fewer labels than it showed,
and the matrix never gained brain badges for those frames.

### Added
- **`EmbeddingWarmer` engine** — the two-phase (rated → unrated)
  warmer is now a first-class singleton with observable
  `isRunning` / `phase` / `done` / `total` / `newlyEmbedded` state
  and `run()` / `cancel()` methods. Re-entrant: calling `run()`
  while a pass is already executing is a no-op.
- **Embeddings chip is now clickable.** Clicking the toolbar chip
  retriggers the warmer. Progress + phase labels update live
  ("scanning…", "rated 1234 / 14900", "unrated …", "complete",
  "click to re-run").
- **Preferences → Advanced → Embedding warmer** — new section with
  full description, a live progress bar, and a Re-run / Cancel
  toggle for the detailed view.

### Changed
- Launch-time trigger (`.task { … }` in `ContentView`) now calls
  `EmbeddingWarmer.shared.run()` instead of an inline private
  method, so the same code path drives the first pass and every
  subsequent retrigger.

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
