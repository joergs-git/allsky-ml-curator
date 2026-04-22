# Allsky-ML-Curator — Claude Code Master Document

> Native macOS (Apple Silicon, Metal-accelerated) image curator with on-device ML.
> **Version:** 0.6.2 — rate → retrain → inspect-mismatches → auto-rate → targeted re-ingest → remove-wrong-ones workflow is end-to-end. Classifier is a two-layer MLP (hidden dim tunable in Preferences); training runs on a detached task so the UI stays responsive during ⌘T; night-only filter soft-hides day / twilight frames from matrix + training; rated tiles where the model disagrees get a dashed orange border + predicted-class badge and can be filtered to as a dedicated rating-filter view; embedding warmer is a start/stop toggle on the Embeddings chip; per-tile moon + auto-reflection risk icons (moon threshold tunable in Preferences, default 30°); class weighting is a per-class boost vector.

---

## Session-start checklist (run mentally every new session)

1. Read `tasks/lessons.md` — internalize all past mistakes for this project.
2. Read `tasks/todo.md` — understand current phase and what's next.
3. Run `git status` and `git pull` (user works from multiple Macs).
4. Confirm `git config user.name` is `joergsflow` and `user.email` is `joergsflow@gmail.com` at the repo level before committing.
5. Identify which lessons apply to today's task.

---

## Project summary

A keyboard-first macOS tool for rating allsky 360° sky imagery with live-learning ML assistance. A curator blasts through hundreds of frames per session — each rated 0 (unrated) / 1 (full clouds) / 2 (mostly) / 3 (some clouds) / 4 (little / thin) / 5 (clear), with orthogonal flags `R` (reflection visible) and `T` (transitional / gain-settling frame). A BNNS-backed logistic-regression classifier retrains after every commit on top of frozen Apple Vision feature-print embeddings, so the next matrix page arrives with prediction overlays the curator can confirm or override. An autonomous auto-rate mode (⌘⇧A) can stream high-confidence predictions into unrated tiles.

The labeled dataset has three downstream consumers:
1. Dynamic seasonal threshold tuning of the AAG CloudWatcher Solo clear/cloudy sky-temperature boundary (the primary "real" goal — deferred, not active work).
2. Weather-aware frame quality ranking in the sibling app `AstroTriage-blinkV2`.
3. A portable cloud/reflection classifier usable at other allsky sites.

---

## Tech stack

| Layer | Technology | Rationale |
|---|---|---|
| UI | SwiftUI + AppKit hybrid | LazyVGrid matrix, `.onKeyPress` for fast keyboard, NSEvent for modifier flags during clicks |
| Rendering | CoreGraphics + ImageIO + Metal | CGImageSource thumbnail fast-path; Metal kernel reserved for later GPU passes |
| ML embedding | Apple Vision `VNGenerateImageFeaturePrintRequest` | 768-dim, ANE-accelerated, OS-bundled |
| Classifier | Accelerate two-layer MLP | Dense → ReLU → Dense → softmax, full-batch softmax-CE GD, ~5 s refit on a 14k-label library, 5-fold CV + per-class P/R/F1. Hidden-dim tunable in Prefs → Training (default 128). |
| Cloud motion | Vision `VNTranslationalImageRegistrationRequest` | Per-frame, between same-camera neighbours, equidistant fisheye scaling |
| Local DB | SQLite via GRDB.swift 7.x | Labels, images, predictions, model versions |
| Remote DB | Supabase REST (URLSession) | **Extends the existing `astro-weather` project** |
| Astronomy | Pure-Swift Schlyter / Meeus | Sun / moon ephemeris |
| File access | SMB mount `/Volumes/AllSky-Rheine/...` | Paths rewritten from `cloudwatcher_readings.allsky_url` |
| Minimum macOS | 14 Sonoma | Apple Silicon only |
| Build system | Xcode 16 + XcodeGen `project.yml` | Matches the sibling `AstroTriage-blinkV2` |

---

## Architectural rules (load-bearing — do not deviate without asking)

1. **Two cameras, never mixed without a one-hot indicator.** `camera_source` is `color_allsky_jpg` / `mono_allsky_jpg` / `mono_allsky_fits`. The mono camera has no usable daylight mode: any mono frame at `sun_alt > −6°` is flagged `is_excluded=1` on ingest and never enters the training set. The classifier's aux-feature vector carries a camera one-hot so the shared head can specialize.
2. **JPG overlay is shown in the UI but masked before ML embedding.** `SkyDiskMask` crops the fisheye circle and neutralizes known overlay-text rectangles (per-camera geometry in Preferences → Camera). The UI keeps the original image; only the `.featureprint` pipeline sees the masked version. The inspection view also shows the original so the curator sees every detail.
3. **Zenith-cone rating, not full hemisphere.** Horizon-exclusion slider + per-camera FoV computes a symmetric crop applied identically to thumbnail and embedding. Rater and model see the same signal.
4. **Reflection (`R`) and transitional (`T`) are orthogonal flags.** `labels.class` (0-5) coexists with `reflection_flag` + `transitional_flag`. Transitional labels carry `sample_weight=0.5` and don't count toward class recall.
5. **No manual quadrant / directional tagging.** v1 is full-disk only. Cloud motion is derived automatically via Vision translational registration + per-camera north-offset calibration.
6. **Extend the astro-weather Supabase project — never spin up a new one.** All new tables (`ml_training_samples`, `ml_predictions`, `ml_model_metadata`) live alongside `cloudwatcher_readings` so joins stay trivial.
7. **Class weighting is a per-class vector, not a single knob.** Inverse-frequency weighting is applied first, then each RatingClass gets its own multiplicative boost from `AppSettings.classWeightBoosts` (5 sliders in Preferences → Training, range 0.1× … 5.0×, default all 1.0×). The 0.4.1-and-earlier "blanket clear-class boost × 3 on classes 4 + 5" was removed in 0.4.2 because it collapsed class 1 on large libraries; the legacy `ml.clearClassBoost` key is migrated automatically (→ `[1, 1, 1, legacy, legacy]`).
8. **Autonomous mode bounds confirmation bias.** Auto-labeled rows have `source='auto'` (provisional, excluded from retrain) or `source='auto_confirmed'` (weighted 0.3×). Autonomous mode is gated behind a minimum human-label count (default 200), live-tunable in Preferences → Training.
9. **Classical Finder / Excel selection semantics.** Plain click / plain arrow / Page / Home / End moves **both** cursor and anchor onto the new tile and collapses selection to `{cursor}`. Shift+arrow / Shift+click / Shift+Page extends via a **single linear range** `linearRange(anchorIndex, cursorIndex)` (row-major, inclusive) for horizontal AND vertical — no row-aligned rectangle, no single-cell horizontal special case. Cursor + anchor are tracked as item IDs, not list indices, so list changes preserve the highlighted tile by identity. **Do not flip this model without an explicit user ask** — every previous deviation was a failed UX attempt. Canonical reference: `feedback_stable_selection_anchor.md` in memory.
10. **Classifier weights blob is version-tagged by featureDim + hiddenDim.** `ClassifierEngine.encodeWeights` emits a **CMLW v2** header with featureDim, hiddenDim, numClasses, and the four MLP tensors (W1, b1, W2, b2). `decodeWeights` returns nil on magic / version / size mismatch; `restoreLatestModel()` falls back to "untrained" silently so growing the aux vector or flipping the classifier topology doesn't crash a restore. Legacy `CMLW v1` (linear logreg, 0.4.x) is rejected — user retrains once after upgrade.

---

## Keyboard map (current)

| Key(s) | Surface | Action |
|---|---|---|
| `0`-`5` | Matrix / List / Inspection | Apply class rating (0 = unrated) |
| `R` | Matrix / List / Inspection | Toggle reflection flag |
| `T` | Matrix / List / Inspection | Toggle transitional flag |
| `Q` | Matrix / Inspection | Arm "quick" (confidence=1) for next digit |
| `C` | Matrix / Inspection | Arm "certain" (confidence=3) for next digit |
| `Esc` | Matrix | Cancel armed confidence |
| `Esc` | Inspection | Close sheet |
| Arrows / Page / Home / End | Matrix / List | Move cursor + anchor together, selection = `{cursor}` |
| Shift + arrows / Page / Home / End / click | Matrix / List | Extend selection via linear range from pinned anchor to new cursor (row-major, inclusive) |
| `⌘A` | Matrix / List | Select all (anchor ← first, cursor ← last) |
| `⌘⌫` / `Delete` / `⌦` | Matrix / List | Prompt to remove the current selection (confirmed alert) |
| Right-click on a tile / row | Matrix / List | Context menu → "Delete N highlighted image(s)" |
| Enter | Matrix | Open inspection view on cursor tile |
| Enter / `Esc` | Inspection | Close back to matrix |
| `⌘⇧A` | Global | Toggle autonomous streaming auto-rate; press again to stop |
| `⌘T` | Global | Retrain classifier (reads live hyperparameters from AppSettings) |
| `⌘O` | Global | Open folder ingest sheet |
| `⌘⇧I` | Global | Open weather-filtered ingest sheet |
| `⌘S` | Global | Manual Supabase sync push |
| `⌘,` | Global | Preferences |

---

## Feature tabs in Preferences

- **Observatory** — lat/lon (default Rheine 52.17°N / 7.25°E).
- **Camera** — per-camera fisheye geometry, FoV, horizon exclusion, north offset (compass calibration for cloud motion).
- **Training** — learning rate, iterations, L2, clear-class boost, autonomous confidence threshold, autonomous min-labels gate, reset-to-defaults.
- **Supabase** — URL + anon key (UserDefaults-backed, env overrides via `SUPABASE_URL` / `SUPABASE_ANON_KEY`).
- **Advanced** — resend-all-ratings and six purge scopes (ratings, classifier model, embeddings, thumbnails, images + caches, everything).

---

## Identity / privacy policy (project-specific)

- Git identity: `joergsflow` / `joergsflow@gmail.com` (verify before every commit at repo scope).
- Apple Developer / notarytool identity: `joergklaas@mac.com` (never in source, commits, or public content).
- No real names, host names, street addresses, personal emails other than `joergsflow@gmail.com` anywhere public.
- `.env` is gitignored; use `.env.example` with `JOHNDOE`-style placeholders.
- No co-authoring lines (`Co-Authored-By:`) in commit messages.
- No "Generated with Claude" watermarks anywhere.

---

## Release workflow

Use the helper script — wraps the full pipeline from the global policy:

```bash
./scripts/release.sh                  # full: archive → export → notarise → staple → gh release
./scripts/release.sh --skip-notarize  # locally signed, no Apple round-trip
./scripts/release.sh --skip-gh        # skip the GitHub release create step
```

One-time bootstrap on a fresh machine:

```bash
brew install xcodegen
xcrun notarytool store-credentials "allskymlcurator-notary" \
  --apple-id "joergklaas@mac.com" \
  --team-id "<YOUR_TEAM_ID>" \
  --password "<app-specific-password>"
```

The script reads `MARKETING_VERSION` from `project.yml` for the tag + filename. Bump that single value before running.

---

## Scope decisions (do not re-open without explicit user ask)

- **FITS v1.1 support** — dropped 2026-04-18. JPG path covers the active workflow.
- **Obstruction-mask editor** — dropped 2026-04-18. Dynamic zenith crop handles the "what to ignore" problem.
- **Manual cardinal-quadrant cloud annotation** — rejected from day one; replaced by automatic cloud motion detection (shipped v0.3.0).
- **Multi-site support** — deferred. `camera_profile_id` hash already differentiates rigs, so existing data stays portable; build the schema / picker when a second observatory is actually coming online.
- **CloudWatcher Solo threshold feedback job** — deferred. User wants this eventually but not in the current wave.

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
