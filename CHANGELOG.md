# Changelog

All notable changes to Allsky-ML-Curator. Format follows
[Keep a Changelog](https://keepachangelog.com/) loosely — one section
per released `MARKETING_VERSION` in `project.yml`.

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
