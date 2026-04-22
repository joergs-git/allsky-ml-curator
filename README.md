# Allsky-ML-Curator

> Native macOS (Apple Silicon, Metal-accelerated) image curator for allsky 360° sky photography, with on-device ML assistance and live learning.

**Version:** 0.6.2 (ML autopilot hyperparameter sweep + moon/sun risk icons)
**Status:** Active development

## Rating semantics — zenith cone, not full hemisphere

Allsky frames cover 180° but rating them as "the whole sky" is the wrong mental model for astrophotography. The horizon ring below ~30° elevation is dominated by atmospheric extinction (5–6× longer optical path at 10° altitude vs zenith), distant cloud bands, ground-level light pollution, and tree / building silhouette — none of which say anything about whether the telescope's current field of view is observable. Even worse, a long exposure (5 min, 1 min) can drift clouds through the horizon ring while the zenith cone the scope is pointed at stays clear the whole time.

The curator therefore rates only the **zenith cone**. Every frame is cropped to an inner circle whose radius is derived from:

```
crop_fraction = (90° − horizon_exclusion°) / (FoV° / 2)
```

assuming an equidistant fisheye projection. The default horizon-exclusion elevation is 30°, which for the Rheine rig resolves to:

- **ZWO ASI676MC color allsky (176° FoV)** → keeps 68 % of the fisheye radius, zenith ± 60° cone
- **SX CCD SuperStar mono (112.5° FoV)** → already tops out above 33° elevation, no crop

Both the matrix thumbnail and the Apple Vision embedding consume the same cropped image — so what the curator sees and what the classifier learns are the same signal. Values live in **Preferences → Camera → Field of view + zenith crop** and can be tuned per setup; changing them invalidates the thumbnail / embedding caches which get rebuilt lazily on next scroll.
**License:** Personal / TBD

---

## What it does

This is a fast keyboard-first labeling tool for rating large batches of allsky images from a fixed observatory. A curator blasts through hundreds of frames per session and tags each one with a cloudiness class (1–5), a reflection flag (R) and a transitional-frame flag (T). In parallel, an on-device classifier retrains after every rating batch and previews its predictions on the next batch — so the curator's workload drops monotonically as the model learns.

The resulting labeled dataset feeds three downstream uses:

1. **Dynamic CloudWatcher Solo threshold tuning** — finding the actual seasonal sky-temperature boundary between "clear" and "cloudy", rather than relying on static K-factor defaults.
2. **Weather-aware quality ranking** — letting [AstroTriage-blinkV2](../AstroTriage-blinkV2/) weight astro-frame quality with real cloud context, not just star metrics.
3. **Portable cloud/reflection classifier** — a model trained at one site that can generalize to other allsky installations.

---

## Primary features

### Rating + curation
- **Matrix view** (4 / 6 / 8 columns) with per-tile prediction overlays, rating stars, R / T flag badges, live cursor pulse, and a selection-count chip.
- **List view toggle** — filename, capture UTC, camera, rating, ingest timestamp, prediction, flags. Scannable table for triage.
- **Single-image inspection sheet** (`Enter`) with metadata sidebar: ephemeris, sensor, per-class probability bars, cloud-motion arrow.
- **Single-frame detail panel** on the right sidebar whenever one tile is selected — filename with **Show in Finder**, Copy-to-clipboard button, full ephemeris / weather / sensor / risk block, every value selectable.
- **Remove images** (`⌘⌫` or right-click → "Delete N highlighted"). Cascades to labels, predictions, thumbnail HEIC, embedding sidecar. Supabase rows kept for re-ingest.
- **Keyboard-first workflow** — `0-5` rate, `R` reflection, `T` transitional, `Q` / `C` confidence prefixes (quick / certain), arrows navigate, Shift+arrows + Shift+click extend the linear range from cursor, `N` night mode, Enter inspects.

### Ingest
- **Folder ingest** (`⌘O`) — recursive scan with camera + format picker.
- **Weather-filtered ingest** (`⌘⇧I`) — pick a sky-temperature range + date window + camera, Supabase fetches the matching `cloudwatcher_readings`, resolves `/volume1/...` → `/Volumes/...`, dedups against the local index, previews count + sample filenames, ingests only the new rows on confirm.
- **Sandbox bookmark persistence** so SMB mount access survives relaunches.

### ML
- **Autonomous streaming auto-rate** (`⌘⇧A`) — writes high-confidence `source='auto'` labels one tile at a time, live counter, mid-run stop. Gated behind a configurable minimum of human labels.
- **Two-layer MLP classifier** (0.5.0+) — Dense(784→hidden, default 128) → ReLU → Dense(hidden→5) → softmax, trained with full-batch softmax-CE gradient descent via Accelerate `cblas_sgemm`. Replaced the linear logistic-regression head that plateaued at ~30 % train accuracy because the "bright overcast day ↔ clear day" boundary in Vision FeaturePrint space isn't linearly separable.
- **UI-reactive training** (0.5.1+) — `train()` dispatches GD + 5-fold CV to a detached `userInitiated` task, so the matrix stays scrollable during the ~5-second fit. Before 0.5.1 the whole MainActor blocked for a minute+ on the full library.
- **Hyperparameter autopilot** (0.6.x) — brain-icon toolbar button opens a sweep sheet that trains 12 configs (class-weight boosts × hidden-dim × feature-scale multipliers × learning rate × iterations), runs 5-fold CV per config, and ranks them by a composite score `CV − 0.5 × (class5→1 + class5→4 leak %)`. One click applies the winner's settings to Preferences and retrains. Typical run takes ~60 s on a Release build. Also surfaced in Preferences → Advanced.
- **Per-class boost vector** (0.4.2+) — 5 sliders in Preferences → Training (one per RatingClass) replace the prior single "clear-sky boost" knob. The autopilot discovered that boosting class-5 while scaling moon/sun/reflection aux features 10-50× drops the class-5 → thin-cloud leak from 38 % to 7 %.
- **Night-only / Day-only filter** (0.5.3+) — soft training + matrix filter on `sun_alt_deg`. Night-only default threshold −18° (astronomical darkness) for the current workflow; day-only slot sits ready for a separately-tuned daytime classifier. Toggles mutually exclusive.
- **Explicit moon/sun visibility features** (0.5.6+) — `moon_phase × sin(moon_alt)` and `sin(sun_alt)` appended to the feature vector as indices 782 / 783. Persisted feature-scale multipliers (indices 777, 782, 783) let the autopilot's winning config carry over to manual ⌘T calls.
- **Mismatch indicator + filter** (0.5.2+) — rated tiles where `prediction.topClass != ratingClass` get a dashed orange inner border + predicted-class badge; the filter dropdown's "Only mismatches" entry surfaces every disagreement for the label-audit pass.
- **Moon + auto-reflection tile icons** (0.5.4+) — golden `moon.fill` when moon is at/above the user-configurable altitude threshold (default 30°, tunable in Preferences), orange `sparkles` when `reflection_risk_score > 0.2`. Opacity scales with intensity so full-moon-at-zenith reads solid, half-moon near threshold reads faint. Sun badge mirrors this for daytime.
- **Classifier persistence** across launches (train accuracy + duration rehydrated from `model_versions.notes`). Blob format version-tagged (CMLW v2); feature-vector shape changes reject old blobs silently and fall back to "untrained" on launch.
- **Embedding warmer as start/stop toggle** (0.5.4+) — click the Embeddings chip to kick or cancel the Vision FeaturePrint walker. Already-written sidecars stay on disk, so the cycle is lossless. Preferences → Advanced has the same control with detailed progress.
- **Forecast aux features** — meteoblue totalcloud + seeing + has-forecast flag denormalised per-frame into the 784-dim aux vector.
- **Cloud motion detection** — Vision translational registration between consecutive same-camera frames yields a °/min rate + compass bearing (when the north offset is calibrated).
- **Geometric reflection + transitional prefilters** — sun / moon / AE-stability feed deterministic risk scores used as aux features. Daytime reflection risk peaks at ~30° sun altitude (plexiglass specular angle) with a 0.7 floor across the daylight band.
- **Dynamic zenith crop** — horizon-exclusion slider + per-camera FoV compute a symmetric cone applied identically to thumbnail and embedding.
- **Two-camera awareness** — color OSC day + night and monochrome ZWO night-only kept as distinct sources; mono-daytime frames auto-excluded.

### Quality-of-life
- Rebuild-missing-thumbnails repair in Preferences → Advanced.
- Launch-time database repairs: `/volume1` path rewrite, `cameraSource` ↔ path consistency, back-filled daytime reflection risk.
- Night mode (red-on-black) for dark-adapted telescope sessions.

Roadmap: multi-site support + CloudWatcher Solo threshold feedback job (v2.x stretch). FITS ingest and obstruction-mask editor were previously listed here and are descoped.

---

## Recommended workflow

Tight loop once the library is ingested:

1. **Rate a batch** — keyboard (`0`-`5`, `R`, `T`) through a few hundred frames.
2. **Retrain** with `⌘T`, or click the brain autopilot button in the toolbar to run the full sweep (~60 s) and apply the winning config automatically.
3. **Audit mismatches** — flip the rating-filter dropdown to "Only mismatches (rating ≠ prediction)". Every rated tile with a dashed orange border + `⚠ N` badge is a disagreement. Opening Inspection (`Enter`) shows full-size image + full per-class probability vector side-by-side.
4. **Correct labels** on the fly — a wrong-label fix via `1`-`5` updates the training set; the classifier's next retrain / next sweep reflects the new ground truth.
5. **Repeat**. The sweep is cheap enough to re-run after every labeling burst — its "composite score" enforces real class-5 recall rather than majority-class accuracy drift.

The moon / sun / auto-reflection icons in the tile bottom-left tell you *why* the classifier might be mispredicting: a moon badge on a class-5 → predicted-as-class-4 mismatch is usually moon glow on a genuinely clear sky; an auto-reflection badge on a class-5 → class-1 mismatch is typically a stray ground-light streak. Tune the moon threshold in Preferences → Training → Overlay thresholds to match your horizon obstruction profile (default 30° works for the Rheine site).

---

## Tech stack

| Layer | Technology | Notes |
|---|---|---|
| UI | SwiftUI + AppKit hybrid | NSCollectionView for the matrix, NSEvent for keyboard |
| Rendering | Metal compute + MTKView | GPU thumbnails, STF stretch (v1.1 for FITS) |
| ML embedding | Apple Vision `VNGenerateImageFeaturePrintRequest` | 768-dim, ANE-accelerated, no model download |
| Classifier head | Accelerate `cblas_sgemm` + vDSP | **Two-layer MLP** (784 → 128 → 5), softmax-CE gradient descent, full-batch, detached task so the UI stays reactive |
| Hyperparameter search | In-app autopilot sweep | 12-config grid, 5-fold CV per config, composite scoring penalising class-5 leak rate, one-click Apply |
| Local DB | SQLite via GRDB.swift 7.x | Labels, images, predictions, model versions |
| Remote sync | Supabase REST (URLSession) | Writes to the existing `astro-weather` Supabase project |
| Astronomy | Pure-Swift VSOP87-lite | Sun / moon altitude, azimuth, phase |
| Minimum OS | macOS 14 Sonoma | Apple Silicon only |
| Build | Xcode 16 + XcodeGen `project.yml` | Matches the sibling `AstroTriage-blinkV2` repo |

---

## Sibling projects this depends on

- **[astro-weather](../astro-weather/)** — Python daemon that writes meteoblue forecasts, AAG CloudWatcher Solo readings and Synology image paths to Supabase every 5 minutes. The curator consumes the paths and weather features but never writes to those tables.
- **[AstroTriage-blinkV2](../AstroTriage-blinkV2/)** — the architectural donor. Metal renderer, NSEvent keyboard handler, app colors, prefetch cache and Supabase REST pattern are ported here.
- **[cloudwatcher-optimizer](../cloudwatcher-optimizer/)** — reference for the clear / cloudy sky-temp thresholds. v2.x will feed the curator's labels back into this project.

---

## Getting started (developer)

### 1. Prerequisites

- macOS 14.0 Sonoma or later
- Xcode 16.x
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- `gh` CLI signed in as `joergsflow`
- Synology NAS with the `AllSky-Rheine` share mounted at `/Volumes/AllSky-Rheine/` (via Finder: `Go → Connect to Server → smb://...`)
- A `.env` file with `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `ASTRO_LAT=52.17`, `ASTRO_LON=7.25` (see `.env.example`)

### 2. Generate the Xcode project

```bash
xcodegen generate
open AllskyMLCurator.xcodeproj
```

### 3. Apply the Supabase migration

The migration in `migrations/001_ml_curator.sql` must be applied to the **existing `astro-weather` Supabase project** (not a new one). Either paste it into the SQL editor in the Supabase dashboard or use `psql` with the project's connection string.

### 4. Build and run

```bash
xcodebuild -project AllskyMLCurator.xcodeproj -scheme AllskyMLCurator -configuration Debug build
```

Or just press ⌘R in Xcode.

---

## Release pipeline (archive + notarize + publish)

Every pushed tag is archived, notarised via Apple Developer ID, stapled and uploaded as a GitHub release. The helper script wraps the whole pipeline:

```bash
./scripts/release.sh                # full release: build → notarise → staple → gh release
./scripts/release.sh --skip-notarize  # local signed build without notarisation
./scripts/release.sh --skip-gh        # produce artefact locally, don't push to GitHub
```

One-time setup on a fresh machine:

```bash
brew install xcodegen
xcrun notarytool store-credentials "allskymlcurator-notary" \
  --apple-id "joergklaas@mac.com" \
  --team-id "<YOUR_TEAM_ID>" \
  --password "<app-specific-password>"
```

The script reads `MARKETING_VERSION` from `project.yml`, so bumping the release number is a single-line change before running it.

---

## Project documents

- **Implementation plan** — see `/Users/joergklaas/.claude/plans/es-geht-um-ein-tidy-tower.md` (not in repo, kept local).
- **CLAUDE.md** — instructions for Claude Code when iterating on this project.
- **tasks/todo.md** — phase-by-phase checklist of v1.0 MVP work.
- **tasks/lessons.md** — session-to-session learnings.

---

## Identity and privacy policy

- Git commits use `joergsflow` / `joergsflow@gmail.com` exclusively.
- The personal Apple ID `joergklaas@mac.com` is used for Xcode Organizer distribution and `notarytool`, never exposed in source code, commits, or any public-facing content.
- No credentials, private keys, or real host/NAS paths are committed. Sample / dev values in this repo use `JOHNDOE` placeholders. See `.env.example`.
