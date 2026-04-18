# Allsky-ML-Curator

> Native macOS (Apple Silicon, Metal-accelerated) image curator for allsky 360° sky photography, with on-device ML assistance and live learning.

**Version:** 0.2.0 (pre-MVP — ingest pipeline usable, UI minimal)
**Status:** Active development, v1 MVP targeted

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

## Primary features (v1.0 MVP)

- 6×6 **live navigable matrix view** with per-tile prediction overlays and reflection/transitional badges.
- Single-image deep-inspection view with metadata sidebar (weather, ephemeris, model probabilities).
- **Keyboard-first** workflow: `0-5` rate, `R` reflection, `T` transitional, arrows navigate, `Shift+arrows` extend selection, `N` night mode.
- **Autonomous Auto-Rate mode** — ML labels the stream, user confirms (`A`) or corrects; session agreement score surfaces continuously.
- **Geometric reflection prefilter** — sun altitude, moon phase and moon altitude drive a deterministic reflection-risk score before any learned model runs.
- **JPG overlay masking** — the `SkyDiskMask` crops the fisheye circle and neutralizes burned-in text rectangles before feeding the image to the ML embedding stage.
- **Twilight transitional detector** — automatically flags gain-settling dusk/dawn frames that would otherwise noise the training set.
- **Live ML loop** — Apple Vision `VNGenerateImageFeaturePrintRequest` embedding + BNNS logistic-regression head, retrained in <200 ms per batch, clear-sky class boosted for rare labels.
- **Two-camera support** — color allsky (day + night) and monochrome ZWO (night only) treated as distinct sources with per-camera JSON profiles.
- **Night mode** — red-on-black palette ported from AstroTriage for dark-adapted vision at the telescope.

Roadmap beyond v1.0: FITS ingest (v1.1), automatic cloud-motion detection via optical flow (v2.0), multi-site support and CloudWatcher threshold feedback (v2.x).

---

## Tech stack

| Layer | Technology | Notes |
|---|---|---|
| UI | SwiftUI + AppKit hybrid | NSCollectionView for the matrix, NSEvent for keyboard |
| Rendering | Metal compute + MTKView | GPU thumbnails, STF stretch (v1.1 for FITS) |
| ML embedding | Apple Vision `VNGenerateImageFeaturePrintRequest` | 768-dim, ANE-accelerated, no model download |
| Classifier head | Accelerate / BNNS | Logistic regression, per-batch retrain |
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

> This project is currently in scaffolding — the Xcode project is not yet generated. These are the steps to bootstrap a dev environment.

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
