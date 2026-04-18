# Allsky-ML-Curator — Claude Code Master Document

> Native macOS (Apple Silicon, Metal-accelerated) image curator with on-device ML.
> **Version:** 0.1.0 — scaffolding phase, v1.0 MVP not yet started.

---

## Session-start checklist (run mentally every new session)

1. Read `tasks/lessons.md` — internalize all past mistakes for this project.
2. Read `tasks/todo.md` — understand current phase and what's next.
3. Run `git status` and `git pull` (user works from multiple Macs).
4. Confirm `git config user.name` is `joergsflow` and `user.email` is `joergsflow@gmail.com` at the repo level before committing.
5. Identify which lessons apply to today's task.

---

## Project summary

A keyboard-first macOS tool for rating allsky 360° sky imagery with live-learning ML assistance. A curator blasts through hundreds of frames per session — each rated 0 (unrated) / 1 (full clouds) / 2 (mostly) / 3 (some clouds) / 4 (thin haze or dust) / 5 (clear), with orthogonal flags `R` (reflection visible) and `T` (transitional / gain-settling frame). A BNNS-backed logistic-regression classifier retrains after every commit on top of frozen Apple Vision feature-print embeddings, so the next matrix page arrives with prediction overlays the curator can confirm (`A`) or correct.

The labeled dataset has three downstream consumers:
1. Dynamic seasonal threshold tuning of the AAG CloudWatcher Solo clear/cloudy sky-temperature boundary (the primary "real" goal).
2. Weather-aware frame quality ranking in the sibling app `AstroTriage-blinkV2`.
3. A portable cloud/reflection classifier usable at other allsky sites.

---

## Tech stack

| Layer | Technology | Rationale |
|---|---|---|
| UI | SwiftUI + AppKit hybrid | NSCollectionView for 36+ tile matrix, NSEvent for fast keyboard |
| Rendering | Metal compute kernels | Ported from `AstroTriage-blinkV2` Shaders.metal |
| ML embedding | Apple Vision `VNGenerateImageFeaturePrintRequest` | 768-dim, ANE-accelerated, OS-bundled |
| Classifier | Accelerate / BNNS logistic regression | In-memory refit < 200 ms per commit |
| Local DB | SQLite via GRDB.swift 7.x | Labels, images, predictions, model versions |
| Remote DB | Supabase REST (URLSession) | **Extends the existing `astro-weather` project** |
| Astronomy | Pure-Swift VSOP87-lite | Sun / moon ephemeris |
| File access | SMB mount `/Volumes/AllSky-Rheine/...` | Paths rewritten from `cloudwatcher_readings.allsky_url` |
| Minimum macOS | 14 Sonoma | Apple Silicon only |
| Build system | Xcode 16 + XcodeGen `project.yml` | Matches the sibling `AstroTriage-blinkV2` |

---

## Architectural rules (load-bearing — do not deviate without asking)

1. **Two cameras, never mixed without a one-hot indicator.** `camera_source` is `color_allsky_jpg` / `mono_zwo_jpg` / `mono_zwo_fits`. The mono camera has no usable daylight mode: any mono frame at `sun_alt > −6°` is flagged `is_excluded=1` on ingest and never enters the training set. The classifier's aux-feature vector carries a camera one-hot so the shared head can specialize.
2. **JPG overlay text must be masked before ML embedding.** `SkyDiskMask` crops the fisheye circle and neutralizes known overlay-text rectangles (defined per camera in `Preferences/CameraProfiles/*.json`). The UI still shows the original thumbnail with overlay intact — only the `.featureprint` pipeline sees the masked version.
3. **Reflection (`R`) is an orthogonal tag, not a 7th class.** `labels.class` (0-5) and `labels.reflection_flag` (0/1) coexist. Moon-reflex on a "3 some clouds" is stored as both.
4. **Transitional (`T`) is also orthogonal.** Gain-settling dusk/dawn frames get `transitional_flag=1` either by detector or by user. They stay in the DB but carry `sample_weight=0.5` and don't count toward class recall.
5. **No manual quadrant / directional tagging.** v1 is full-disk only. v2.0 derives cloud motion automatically via optical flow + per-camera N/S/E/W preset.
6. **Extend the astro-weather Supabase project — never spin up a new one.** All new tables (`ml_training_samples`, `ml_predictions`, `ml_model_metadata`) live alongside `cloudwatcher_readings` so joins stay trivial.
7. **Class-5 (clear) gets a 3× boost on top of inverse-frequency weighting.** Rheine nights are dominantly cloudy; without the boost, rare clear samples are statistically invisible.
8. **Autonomous mode must bound confirmation bias.** Auto-labeled rows have `source='auto'` (provisional, not used in retrain) or `source='auto_confirmed'` (weighted 0.3× vs. human). Autonomous mode is disabled until ≥200 human labels exist.

---

## Reuse from AstroTriage-blinkV2

Port these files (verbatim where possible, adapt imports / module names):

- `Metal/MetalRenderer.swift` + `Metal/Shaders.metal` + `Metal/TexturePool.swift` — GPU pipeline
- `UI/KeyboardHandler.swift` — NSEvent local monitor pattern
- `UI/AppColors.swift` — night-mode red-on-black + tier colors
- `Engine/PrefetchCache.swift` — dual-queue thumbnail prefetch
- `Engine/TargetCatalogService.swift` — Supabase REST + disk TTL cache pattern
- `Bridge/ImageDecoder*` — FITS/XISF decoding (**v1.1 only, skip for MVP**)

**Do not reuse** `MosaicGenerator.swift` — that produces a monolithic VLM JPEG. The curator's matrix is a live, navigable NSCollectionView, not a baked mosaic.

---

## Identity / privacy policy (project-specific)

- Git identity: `joergsflow` / `joergsflow@gmail.com` (verify before every commit at repo scope).
- Apple Developer / notarytool identity: `joergklaas@mac.com` (never in source, commits, or public content).
- No real names, host names, street addresses, personal emails other than `joergsflow@gmail.com` anywhere public.
- `.env` is gitignored; use `.env.example` with `JOHNDOE`-style placeholders.
- No co-authoring lines (`Co-Authored-By:`) in commit messages.
- No "Generated with Claude" watermarks anywhere.

---

## Publish workflow (every release)

After every feature commit + push:

1. `xcodegen generate` if `project.yml` changed
2. Archive in Xcode (⌘B → Product → Archive, or `xcodebuild archive`)
3. Distribute via Xcode Organizer → Developer ID with Apple ID `joergklaas@mac.com`
4. `xcrun notarytool submit` on the signed zip; wait for green
5. Staple (`xcrun stapler staple`)
6. Upload the notarized zip to the GitHub Releases tab

---

## Commit message conventions

Follow the sibling AstroTriage style. Prefixes:
- `feat:` — new functionality
- `fix:` — bug fix
- `refactor:` — structural change, no behavior change
- `docs:` — docs / comments only (state clearly in the body if comments-only)
- `chore:` — dependency / config maintenance
- `style:` — formatting only

Example: `feat: SkyDiskMask crops fisheye + masks overlay before embedding`.

Bump `MARKETING_VERSION` in `project.yml` for every pushed tag.
