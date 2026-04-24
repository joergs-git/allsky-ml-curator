# Changelog

All notable changes to Allsky-ML-Curator. Format follows
[Keep a Changelog](https://keepachangelog.com/) loosely — one section
per released `MARKETING_VERSION` in `project.yml`.

## [0.8.8] — 2026-04-24

**Embedding warmer honours Night-only / Day-only.** Previously the
warmer pulled every unrated frame regardless of sun altitude and
ran Vision extraction on all of them — on Rheine's library that's
~71 000 daytime colour frames that never enter the matrix (because
night-only is on) or training (same). ~61 % of the work was pure
waste. Now it reads `AppSettings.nightOnlyMode` / `dayOnlyMode` and
filters at the SQL level, just like the matrix reload does.

### Changed
- **`ImageLibrary.fetchRatedImages` + `fetchUnratedImages`** gain
  optional `maxSunAltDeg` / `minSunAltDeg` parameters (default nil
  = no filter, preserves existing callers).
- **`EmbeddingWarmer.performRun`** reads the two filter values from
  `AppSettings` and passes them through. Toggling Night-only off
  and re-running the warmer picks up the previously-skipped
  daytime frames.

## [0.8.7] — 2026-04-24

**Multi-folder ingest.** The NAS layout is one `YYYY-MM-DD/`
directory per night; rebuilding a library after a purge used to
mean opening the ingest sheet once per night. Now ⌘O's picker
accepts a multi-selection and the sheet holds a queue — a month
of backfill = one click, one scan pass.

### Added
- **`IngestService.ingestFolders(_:cameraType:imageFormat:dryRun:)`**
  — scans each folder in sequence under a single `isRunning`
  window, a single `cancelToken` (Cancel halts the entire batch),
  and shared counters so "inserted X of Y" reflects the whole
  pass, not just the last folder. Status message ticks
  `folder N of M — scanning …`.
- **`IngestSheet` multi-select** — picker's
  `allowsMultipleSelection = true`. A new queue list below the
  Add button shows every folder with a remove (✕) and a Clear
  shortcut. Primary action button label reflects count:
  "Ingest 12 folders".
- **`IngestService.processOneFolder(...)`** — private helper that
  does the per-folder work (scan + enrich + write) without
  resetting counters or flipping `isRunning`. `ingestFolder()`
  becomes a thin wrapper around `ingestFolders([url])`.

## [0.8.6] — 2026-04-24

**Delete becomes soft-exclude; re-ingest no longer resurrects it.**
Previously `Delete` / `⌘⌫` / right-click `Delete` ran `DELETE FROM
images`, and the weather-filtered ingest deduped only on `filePath`.
Result: the "deleted" files walked straight back in on the next
ingest pass because the DB no longer knew their path. The delete
action felt useless; actual junk couldn't be kept out.

### Changed
- **`ImageLibrary.deleteImages()`** is now an `UPDATE images SET
  isExcluded = 1 WHERE id IN (...)` — soft-exclude, not hard delete.
  The row survives, labels + predictions stay for audit, but
  thumbnails + Vision FeaturePrint sidecars are still purged
  (disposable, cheap to regenerate). Re-ingest dedup naturally
  blocks re-insertion because the filePath is still in the DB.
- **Confirm alert copy** now says "Exclude N frames" and explains
  that re-ingest will NOT bring them back, plus how to restore.
- **Context menu** button flips verb/icon based on current filter.

### Added
- **`RatingFilter.excluded`** — "Only excluded (trash)" option in
  the rating filter picker. Shows the soft-exclude pile so the
  curator can audit or recover mistakes.
- **`ImageLibrary.restoreImages()`** — inverse of the exclude.
  Flips `isExcluded = 0`; sidecar / thumbnail warmer regenerates
  caches on the next pass. UI exposure: in the trash-bin view,
  Backspace + right-click context menu run Restore instead of
  Exclude, with alert copy to match.

## [0.8.5] — 2026-04-23

**"How to start" floating reference in the toolbar.** The idiomatic
workflow (bootstrap once → sweep once → loop on auto-rate / audit /
retrain / re-ingest) is load-bearing and easy to get wrong — e.g.
running the sweep every iteration instead of once per phase, or
expecting auto-rate to rewrite human labels. One discoverable button
on the left of the toolbar, a floating window that stays on top
while you work.

### Added
- **"How to start" toolbar button** — graduation-cap icon next to
  the brand badge, accent-tinted capsule. Opens a floating window.
- **`HowToStartView`** — two-phase workflow guide: Phase 1
  Bootstrap (ingest → embed → rate → train → sweep once) and
  Phase 2 Daily Loop (auto-rate → audit → retrain → targeted
  re-ingest). Plus "when to re-run the autopilot" and "good to
  know" nuance blocks (embed is permanent, train cheap, sweep
  expensive, auto-rate non-destructive, ⌘T trains both cameras).
- **`HowToStartWindowController`** — singleton manager for the
  floating NSWindow. `level = .floating` keeps it above the main
  matrix; second click on the toolbar button brings the existing
  window forward rather than spawning duplicates; auto-nils on
  close so the next open is clean.

## [0.8.4] — 2026-04-23

**Sweep gets a camera scope + a "hunt class-2 by sky-temp" seeding
helper in the weather-filtered ingest.** 0.8.2 shipped two per-
camera MLPs but the sweep stayed camera-blind, pulling all rated
samples and fitting a mixed classifier — the autopilot's ranking
had no idea which camera it was tuning. Parallel problem on the
data side: mono currently trains on 385 class-2 samples (7 % of the
set) and colour on only 17 — not enough for either model to learn
the boundary well. The seeding helper uses the existing class-2
sky-temp distribution to propose more-likely-class-2 candidates.

### Added
- **Sweep camera scope picker** (`HyperparamSweepView`): segmented
  `Colour` / `Mono` next to the Run button. Default `.color`.
  Disabled while a sweep is running so a mid-run swap can't
  corrupt the in-flight ranking.
- **`ClassifierEngine.sweep(_:cameraScope:)`** — optional camera
  filter, plumbed through to `loadTrainingSet(cameraType:)`. Error
  message now names the scope when a filter ends up empty so the
  user knows *which* camera has zero samples.
- **"Seed window from current class-2 labels" button** in
  `WeatherIngestSheet` (next to the sky-temp fields). Reads the
  IQR (p25…p75) of the currently-labelled class-2 frames for the
  selected camera from the local DB, pads ±0.5 °C, and widens the
  date window to all-time (2023-01-01 → today). One click
  transforms the sheet from "pick a temperature by intuition" to
  "hunt the temperature range where class-2 actually lives".
- **`CameraType.filePathCameraSources`** — raw-value list of the
  `ImageRecord.CameraSource` cases that belong to a camera type.
  Exposed on the enum so UI code can build WHERE-IN clauses without
  going through the private `ImageLibrary.sources(for:)` helper.

### Fixed
- "ready to train" coverage subtitle said `N/5 classes` since 0.8.0
  collapsed the scheme to three. Now reads `N/3`. (slipped from
  0.8.3; repeated here for release-notes clarity)

## [0.8.3] — 2026-04-23

**Per-camera classifier surfacing in the info side panel.** 0.8.2
trained one MLP per camera but the sidebar was hard-wired to
`.color`'s summary, so a curator inspecting a mono frame saw colour
CV / colour class counts / colour duration regardless. 0.8.3 routes
the panel to whichever camera the user is currently looking at.

### Added
- **`ClassifierEngine.cameraSummaries` + `.cameraCoverages`** —
  `@Published` dicts keyed by `CameraType`. Populated on every
  `trainOne(cameraType:)` completion and on `restoreLatestModel()`
  per scope. Headline `summary` / `lastCoverage` stay around for
  backward compatibility with the toolbar chip.
- **`InfoSidePanel.activeCamera`** — computed property that picks
  the camera scope the panel surfaces: single selection →
  selected frame's camera; homogeneous matrix view → that camera;
  mixed → `.color`.
- **Camera scope pill** next to the "CLASSIFIER" section header
  (`COLOUR` in warm orange, `MONO` in slate grey). Makes the scope
  unambiguous so 86 % on a colour frame vs 83 % on a mono frame
  are clearly two separate numbers, not one drifting.
- **Classifier summary + coverage + class counts + confusion matrix
  + per-class P/R/F1** all now come from the active-camera slot.
  Select a mono tile → mono's CV, mono's confusion matrix, mono's
  support counts. Select a colour tile → colour's.

### Fixed
- **"ready to train" subtitle** said `N/5 classes` since 0.8.0
  collapsed the scheme to three. Now reads `N/3 classes`.

## [0.8.2] — 2026-04-22

**Two classifiers instead of one** — separate MLP per camera type
so colour OSC and monochrome don't have to share a single shared
decision boundary through a heterogeneous 768-dim Vision
FeaturePrint space.

### Why
0.8.1 with mono data added dropped CV from 87 % (colour-only) to
79 % (combined). Root cause: Vision FeaturePrint was trained on
colour imagery; mono frames cluster in a different part of the
768-dim embedding space. A single `camera_one_hot` aux feature
isn't enough signal for the shared MLP to internally route
predictions per camera at our sample scale — the classifier mixes
both distributions and under-performs on both.

### Added
- **Per-camera models** in `ClassifierEngine`: internal
  `models: [CameraType: CameraModel]` dict. One fresh MLP for
  `.color`, one for `.monochrome`. Each has its own weights, its
  own `TrainingSummary`, its own `TrainingCoverage`.
- **`⌘T` trains both cameras** sequentially in one pass. Cameras
  with too few samples / too few distinct classes are silently
  skipped (so a colour-only install doesn't surface "mono failed
  to train" errors). Training dispatches to the normal detached
  task per camera, so the UI stays reactive throughout.
- **`predict(image:)` routes per camera** — reads
  `image.cameraSource.cameraType`, looks up the right model from
  the dict, falls back to nil when that camera hasn't been
  trained yet. `recomputeAllPredictions()` does the same dispatch
  per frame.
- **Database migration v9** (`v9_add_model_camera_scope`) adds a
  nullable `cameraScope TEXT` column to `model_versions`. Pre-
  0.8.2 rows have NULL here and `restoreLatestModel()` treats them
  as `.color` (which matches reality — legacy installs only had
  colour data).
- **`ModelVersionRecord.cameraScope: CameraType?`** — persisted +
  decoded in the custom Row initialiser so the classifier table
  can carry one row per camera per train.
- **`restoreLatestModel()` picks latest row per camera scope** —
  walks rows newest-first, stops when it has one per
  CameraType.allCases. Both scopes get decoded and populated into
  the `models` dict; the headline `summary` / `lastCoverage`
  UI bindings prefer `.color`'s summary and fall back to
  `.monochrome` if only mono has been trained.
- **`loadTrainingSet(cameraType:)`** gains the per-camera filter.
  Stacks cleanly with the existing `nightOnlyMode` /
  `dayOnlyMode` sun-altitude predicates.

### Expected behaviour
- Colour CV returns to ~87 % (the pre-mono level); mono gets its
  own CV number trained on mono-only samples.
- On ⌘T you'll see two train durations add up (~10-20 s total on
  the current Rheine dataset).
- Old pre-0.8.2 blob survives migration as the colour model;
  first ⌘T overwrites it per-scope.

### Fixed alongside
- Version string in the window title was stuck at 0.6.3 across
  several 0.7.x / 0.8.x releases because `xcodegen generate`
  wasn't part of the rebuild chain — the Info.plist kept the
  stale `MARKETING_VERSION`. 0.8.2 rebuild forces a regenerate
  so the title bar now matches `project.yml`.

## [0.8.1] — 2026-04-22

### Fixed
- **Crash during training** — `InfoSidePanel.confusionMatrixView`
  hardcoded `K = 5` for the grid loop, so when the 0.8.0 3-class
  classifier wrote a 9-element (3×3) confusion matrix into the
  summary, the view tried to index `matrix[row * 5 + col]` and hit
  index-out-of-range on the first off-diagonal cell. Now derives K
  from `sqrt(matrix.count)` so the same view works for any
  numClasses. Crashed on every ⌘T since 0.8.0.
- Same hardcoded-5 assumption in two other helpers:
  `InfoSidePanel.classCountsBreakdown` and
  `ClassifierEngine.TrainingError.countsBreakdown` — both swapped
  to `counts.enumerated()` so the label comes from the array
  position, not a parallel fixed-length string array.

## [0.8.0] — 2026-04-22

**RatingClass collapsed from 5 to 3 values.** The 5-class
meteorological-okta scheme (full clouds → mostly → some → thin →
clear) produced unresolvable label ambiguity on half the frames —
"50 % horizon cloud but clear zenith" / "flat thin overcast with
stars showing through" / "fog with stars visible" have no
unambiguous okta mapping. The 3-class scheme asks the only
question the downstream consumers actually care about: **can I
image through this?**

### Added
- New `RatingClass` values: `unrated` (0), **unsuitable** (1,
  don't image), **partial** (2, mosaic / wide-field only),
  **suitable** (3, full-quality imaging).
- Colour-pill rating badge on matrix tiles — red / amber / green
  capsule with the class digit in bold white, replacing the 1…5
  star cluster. Reads at a glance at any grid size, and matches
  traffic-light intuition.
- `RatingClass.distance(to:)` still present but now maxes at 2
  instead of 4. Distance-aware mismatch borders simplify to amber
  (distance 1, adjacent slip) → red (distance 2, extreme flip).
- **Three prominent colour-pills** in the Inspection rating hero —
  filled for the current rating, outlined for the alternatives.
  Same keyboard: 1 / 2 / 3 toggle, 0 clears, 4 / 5 swallowed so
  old muscle memory doesn't write garbage.

### Migration
- **Migration v8** (`v8_remap_rating_classes_to_three_class`)
  runs automatically at first launch. Single atomic `CASE` remap
  of every existing `labels.ratingClass`:
  - old {1, 2} (full + mostly) → **1 (unsuitable)**
  - old {3}    (some)            → **2 (partial)**
  - old {4, 5} (thin + clear)    → **3 (suitable)**
- Per-class boosts migrate symmetrically:
  `new[unsuitable] = mean(old[0], old[1])`,
  `new[partial] = old[2]`,
  `new[suitable] = mean(old[3], old[4])`.
- Existing classifier blobs (`CMLW v2`, numClasses = 5) rejected
  by `decodeWeights` since the header's numClasses no longer
  matches runtime (3). Silent fallback to "untrained"; ⌘T
  retrains on the new 3-class target.

### Changed
- `ClassifierEngine.numClasses = 3`. `SweepResult` fields renamed:
  `class5Recall → suitableRecall`,
  `class5ToClass1Count → suitableToUnsuitableCount` (distance-2
  flip), `class5ToClass4Count → suitableToPartialCount`
  (distance-1 slip), `class1Recall → unsuitableRecall`,
  `class1Precision → unsuitablePrecision`.
- Composite score: `1 − MAE / 2` (max MAE is now 2 instead of 4).
  Typical good-model scores ~0.85–0.97. Prior 0.7.x scores are
  not comparable — different denominator.
- All sweep preset names updated — "class5 2.0×" became
  "suitable 2.0×"; classBoost vectors inside presets shrunk to 3
  slots.
- Rating filter pulldown: `Only ★` / `Only ★★★★★` entries become
  `Only 1 — unsuitable` / `Only 2 — partial` / `Only 3 — suitable`.
- Keyboard cheat-sheet in Inspection updated: 1 / 2 / 3 rates
  explicitly, 0 clears, 4 / 5 silently ignored.
- InfoSidePanel class-count rows: three rows in
  suitable → partial → unsuitable order with colour-pill badges
  matching the matrix tiles.

### Rationale
The meteorological-okta granularity turned out to be the #1
source of label noise in the 0.5.x → 0.7.x audit cycle. Neither
human nor classifier could consistently resolve border cases
between adjacent classes. Collapsing to 3 classes along the
actual decision axis (can-I-image?) removes that ambiguity,
raises the theoretical accuracy ceiling, and matches how
AstroTriage-blinkV2 and the CloudWatcher threshold-tuner want to
consume the labels downstream.

## [0.7.6] — 2026-04-22

### Fixed
- **Window management gets stuck after maximise** — green-button
  fullscreen could leave the window chrome drifting outside the
  visible screen area, hiding the menu bar and the traffic lights
  so the user couldn't exit or shrink back. Three changes fix it:
  1. `.defaultSize(width: 1400, height: 900)` so the app opens at a
     sensible size instead of the 1100 × 720 content minimum.
  2. `.windowResizability(.contentSize)` ties the window frame
     strictly to the content's min/max, which makes macOS 14+
     full-screen transitions round-trip cleanly.
  3. New **Window → Reset Window** menu item (`⌃⌘0`) as an escape
     hatch — exits full-screen if active, resets the window to
     1400 × 900, re-centres on the current screen. Works even
     when the title bar is out of reach.

## [0.7.5] — 2026-04-22

### Changed
- **Inspection view redesigned to three-column layout** — left
  metadata (Time, Ephemeris, Sensor, Cloud motion), centre image,
  right rating + prediction + keyboard cheat-sheet. No scrollbar
  at the 780-pt minimum height so every audit-relevant field is
  visible at once.
- Minimum window size bumped from 900 × 600 to 1320 × 780 to
  accommodate the three-pane layout while keeping the image at
  readable size (~660 pt square at the minimum height).
- **Big rating hero** on the right pane — five stars at 22 pt
  (same tier colour as the matrix tile band), class name +
  coverage hint, source + sample weight + flags. When unrated, a
  dim placeholder + "Press 0-5 to rate" hint.
- **Keyboard cheat-sheet** card at the bottom of the right pane
  tells the curator they can rate, flag, and ←/→ through the
  audit set without closing the sheet — the workflow the redesign
  enables.

### Kept
- Arrow-key navigation, 0-5 rating, R / T flag toggles, Q / C
  confidence prefixes all work unchanged — the keyboard path was
  already there from 0.4.x, the redesign just surfaces it
  explicitly.

## [0.7.4] — 2026-04-22

RatingClass is totally ordered (cloudiness is monotonic), but
every metric so far treated misclassifications as binary
equal-weight. A 5 → 4 slip and a 5 → 1 flip counted the same.
This release scores errors by ordinal distance so adjacent misses
barely move the needle and extreme flips are punished hard.

### Added
- **`RatingClass.distance(to:)`** — `abs(a.rawValue − b.rawValue)`
  for rated classes, 0 otherwise. Single source of truth for every
  distance-aware metric.
- **Distance-aware mismatch borders** on matrix tiles: amber
  (distance 1, likely label-boundary noise) → orange (2) → deep
  orange (3) → red (4, extreme flip). The curator can triage
  severity from the matrix at a glance without opening Inspection.
- **Mean Absolute Error column** (`MAE`) in the sweep results
  table. Computed from the CV confusion matrix as
  `Σ|true − pred| × count / totalSamples`. 0.3–0.5 is typical for
  a well-tuned 5-class ordinal classifier at our data scale.
- **`ClassifierEngine.meanAbsError(confusion:numClasses:)`** — pure
  nonisolated static helper so the sweep can compute MAE off the
  main actor alongside the existing confusion bookkeeping.

### Changed
- **Composite score switched to distance-aware**: `1 − MAE / 4`.
  Previous scores (`CV − 0.5 × leak rate`) are not comparable to
  the new ones; typical good-model scores now land in the 0.85–0.95
  range instead of 0.70–0.75. Ranking inside a sweep is still
  consistent, just with a different absolute scale.
- Sweep results table + Copy-to-clipboard markdown both now include
  the MAE column.
- Sweep help section updated to explain the distance-aware
  rationale and column semantics.

## [0.7.3] — 2026-04-22

### Changed
- **Split mismatch filter out of `RatingFilter`** into an orthogonal
  toggle next to the rating pulldown. Before: one pulldown entry
  "Only mismatches" was mutually exclusive with the 1-5 star rating
  filters. After: independent ⚠-icon toggle that composes with any
  rating filter — e.g. "Only ★★★★★" + Mismatches on = audit just
  the class-5 leaks. "Any rating" + Mismatches on = full audit set
  across all classes (previous behaviour).
- `RatingFilter` enum loses its `.mismatches` case; the toggle is
  now a plain `@State var onlyMismatches: Bool` in `ContentView`,
  applied as a post-fetch predicate in `reload()`.

## [0.7.2] — 2026-04-22

### Added
- **SQM backfill button** — Preferences → Advanced → "SQM backfill".
  Walks every image row with `supabaseReadingId != nil` and
  `cloudwatcherSkyQualityRaw IS NULL`, batch-fetches (500 reading
  ids per request) from Supabase, writes the value into the local
  `images` table. Live progress, cancelable. Idempotent — rows
  already populated are skipped, safe to re-run.
- **`SupabaseClient.fetchCloudwatcherReadings(ids:)`** — PostgREST
  `id=in.(…)` filter. Complements the existing time-window fetch.
- **`ImageLibrary.backfillSkyQuality(progress:)`** — reusable engine
  method returning `SkyQualityBackfillResult` with counters for
  updated / missing on Supabase / reading had no SQM value.

## [0.7.1] — 2026-04-22

### Added
- **CloudWatcher SQM aux feature (indices 790, 791)** — denormalised
  `sky_quality_raw` on `ImageRecord` via migration `v7_add_cloudwatcher_sky_quality`. Ingest pipeline populates it when a cloudwatcher reading pair is found, identical flow to the existing `cloudwatcherSkyTempC`. Feature layout: `has_sqm` flag + `sqm_raw / 15000` normalised value. Higher raw = darker sky; city-light scatter under cloud drops it. Direct sky-brightness prior the Vision embedding can't replicate.
- **`featureSkyQualityEnabled` toggle** in Preferences → Training →
  Feature groups. Off during early rollout if existing library has
  mostly nil `sky_quality_raw` values and you want the model to
  ignore the feature until backfill coverage improves.

### Deferred
- **Backfill button** for existing rows with NULL sky_quality_raw —
  would walk `images` where `supabaseReadingId` is set and SQM is
  missing, batch-fetch from Supabase. Left as a 0.7.2 TODO to keep
  this change focused; for now new ingests get the column, older
  rows emit `has_sqm = 0` in the feature vector.

### Required action
Feature vector grows 790 → 792. Existing `CMLW v2` blobs rejected on
launch; hit ⌘T to retrain. Autopilot-tuned scales persist.

## [0.7.0] — 2026-04-22

Feature-vector expansion — three new aux-feature groups designed to
attack the residual failure modes the 0.6.x autopilot sweep hit a
ceiling on. Vector dim 784 → 790, all groups individually toggleable.

### Added
- **Seasonal encoding (indices 784, 785)** — `sin / cos(2π × day_of_year / 365.25)`. Captures the site's seasonal light / humidity / twilight-duration patterns without committing to a calendar shift at year boundary.
- **Exposure + gain (786, 787)** — `clamp(exposure_sec / 120, 0…1)` and `clamp(gain / 500, 0…1)`. Normalises frame brightness so the classifier can separate "bright because long exposure" from "bright because cloudy".
- **Image-texture variance (788, 789)** — `has_sky_variance` flag + luminance std-dev normalised by 128. Computed from the already-zenith-cropped HEIC thumbnail via `SkyVarianceCache`, cached in-process on first read. Smooth moon glow → low variance; structured cloud → high variance. The residual class-5 ↔ class-4 confusion after the 0.6.x autopilot was visually "gradient smoothness" — this gives the classifier that signal directly without needing to derive it from the 768-dim Vision embedding.
- **Preferences → Training → "Feature groups (on / off)"** — three toggles (Seasonal, Exposure + gain, Sky texture). When off, the corresponding feature dims emit zero; vector shape stays constant so toggling doesn't invalidate the persisted classifier, but a retrain is needed to re-learn the weights that were previously zeroed.
- **`SkyVarianceCache`** — thread-safe singleton, in-memory only, lazily populates from the thumbnail cache. Cold-cache training cost: ~5-10 s extra on a 14 k-sample library; subsequent trains / sweeps hit the cache. Drops on thumbnail rebuild (variance no longer matches the on-disk HEIC then).

### Required action
Existing `CMLW v2` classifier blobs are rejected on launch because the featureDim in the stored header (784) no longer matches the runtime vector (790). The app falls back to "untrained"; hit ⌘T once to retrain on the 790-dim vector. If you were using autopilot-tuned settings (moon×50 etc.) they persist through the bump — only the model weights are re-learnt.

### Deferred
- **CloudWatcher `sky_quality_raw`** — already fetched from Supabase but not stored on `ImageRecord`. Adding it as a feature needs a migration + ingest-time denormalisation. Target: 0.7.1.
- **Previous-frame prior** — strong signal (clouds don't teleport) but needs a temporal join during feature build. Target: 0.8.

## [0.6.3] — 2026-04-22

### Added
- **Manual feature-scale sliders** in Preferences → Training →
  "Feature-vector scales (advanced)". Three sliders for
  `featureMoonVisibilityScale`, `featureSunVisibilityScale`,
  `featureReflectionRiskScale` (range 1× … 100×, step 1×). Lets
  the curator experiment without re-running the autopilot —
  useful for quickly seeing "what if I crank moon×80". Reset
  defaults covers them too.

## [0.6.2] — 2026-04-22

Rounds out the ML autopilot into a first-class workflow tool:
persisted feature scales, prominent toolbar button, expanded in-app
help, and docs / memory refresh.

### Added
- **Toolbar autopilot button** (brain icon) next to the auto-rate
  button — single-click to open the sweep sheet. Turns blue while a
  sweep is running so the state is visible globally, not just
  inside the sheet.
- **Inline help section** in the sweep sheet (`?` button in the
  header, bottom-up) — question → answer blocks covering why the
  sweep exists, what each column means, what the composite score
  penalises, what the 12 configs probe, what Apply actually does,
  when to re-run, and when it won't help.
- **Persisted feature-scale multipliers** —
  `AppSettings.featureMoonVisibilityScale`,
  `featureSunVisibilityScale`,
  `featureReflectionRiskScale`. Applied inside
  `FeatureVectorBuilder.aux()` so a manual ⌘T after the autopilot
  Apply keeps the same feature conditioning. Before 0.6.2 the
  sweep's winning scale values were diagnostic only and a retrain
  silently regressed to baseline.
- **Autopilot Apply now writes all scales**, not just the
  hyperparameters. One click → everything the winning config
  encodes is live.

### Changed
- `ClassifierEngine.sweep()` neutralises persisted scales for the
  duration of a run (via `defer` restore) so per-config scaling
  stacks cleanly on a baseline vector rather than compounding
  with AppSettings.
- **README.md**: version bump to 0.6.2, ML section rewritten for
  the MLP + autopilot era, new "Recommended workflow" section.
- **tasks/lessons.md**: three new lessons (MLP feature-scale
  amplification, automate-over-handtune, run ML sweep in-app
  rather than XCTest).
- **Memory (per-project)**: added `feedback_ml_autopilot_sweep.md`
  (prefer the sweep over hand-tuning) and
  `project_classifier_architecture.md` (current topology + 784-dim
  vector + persisted scales).
- **tasks/todo.md**: captures the confirmed winning config
  (composite 0.714, class-5 leak 38 % → 7 %) as the Rheine
  baseline for future regression checks.

## [0.6.1] — 2026-04-22

### Added
- **Copy-to-clipboard button** in the sweep sheet header. Exports
  the full ranked table as markdown (winner **bold**, leak cells
  tagged 🟠 / 🔴 for >10 % / >25 % so the severity survives plain
  text) and includes the exact settings the winner would apply.
  Saves the round-trip through a screenshot when sharing results.

## [0.6.0] — 2026-04-22

**ML hyperparameter autopilot**. First-class in-app sweep over
class-weight / hidden-dim / learning-rate / iterations / L2 /
feature-scale combinations. The 0.5.6 moon-visibility feature
alone didn't break the class-5 → {1, 4} moon-glow leak; the right
answer was systematic search over config space rather than
single-knob tuning.

### Added
- **`ClassifierEngine.SweepConfig` / `SweepResult` / `SweepStatus`**
  public types. Sweep API runs GD + 5-fold CV for each config and
  ranks by a composite score `cvAccuracy − 0.5 × (class5→1 + class5→4)`,
  targeting the moon-glow misclassification pattern the 0.5.x audit
  surfaced.
- **`ClassifierEngine.sweep(configs:)`** that walks the grid and
  publishes live progress through `@Published var sweepStatus`.
  Heavy math dispatched to a detached `userInitiated` task so the
  UI stays reactive during the ~60 s run.
- **`ClassifierEngine.defaultSweepGrid()`** — 12 preset configs
  covering three axes:
  1. moon/sun/reflection feature scaling (×10, ×50, ×100, ×20 mix)
  2. class-5 per-class boost (1.5×, 2.0×) layered on feature scaling
  3. hidden-dim capacity (256, 512) with moderate scaling
  plus a baseline and a kitchen-sink "aggro" config.
- **Per-sample feature-vector scaling** applied at sweep time to
  indices 777 (`reflection_risk_score`), 782 (`moon_visibility`),
  and 783 (`sun_visibility`). Lets the sweep probe whether the MLP
  actually uses those interaction signals when they dominate the
  input magnitude.
- **`HyperparamSweepView` sheet** — Preferences → Advanced →
  "Hyperparameter sweep (autopilot)" → "Run sweep…". Live progress
  bar + current-config label while running; per-config ranked table
  (config, CV, cls-5 recall, 5→1 / 5→4 leak counts + %, cls-1 P,
  composite score) when done. Each row has an **Apply** button that
  writes the matching settings back into `AppSettings` and kicks a
  fresh `train()` so the live model immediately reflects the pick.
  Feature-scale multipliers aren't persisted yet — the sweep is
  diagnostic for those.

### Notes on the workflow
Sweep respects the current Night-only / Day-only / camera filters.
Run it with Night-only on to tune the night classifier; flip to
Day-only later to tune the (eventual) day classifier separately.
Label quality caps accuracy at roughly `1 − labelNoise`, so a
sweep converging at ~65–70 % on Rheine with ~20 % label noise is
near its theoretical ceiling — the leak-count columns are the
honest metric to watch.

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
