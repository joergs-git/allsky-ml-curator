import AppKit
import SwiftUI

/// Onboarding / workflow reference. Opens in a standalone floating
/// NSWindow (via `HowToStartWindowController`) — non-modal, user can
/// keep it visible next to the main matrix while they work.
///
/// Content is a static workflow guide tuned to the 0.8.x wave:
/// per-camera classifier, sweep-as-an-occasional-step, auto-rate on
/// unrated-only, class-2 sky-temp hunt. Section structure lets the
/// reader skim or drill in.
struct HowToStartView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                phaseBlock(
                    index: 1,
                    tint: .blue,
                    title: "Bootstrap — once per camera / new dataset",
                    icon: "sparkles",
                    steps: [
                        Step(icon: "tray.and.arrow.down",
                             title: "Ingest",
                             body: "⌘O for a folder, ⌘⇧I for weather-filtered ingest from Supabase. Class-2 hunt: in the weather sheet, tap ‘Seed window from current class-2 labels’ to mirror the IQR of your existing partial frames."),
                        Step(icon: "cpu",
                             title: "Embed (automatic)",
                             body: "Apple Vision FeaturePrint sidecars get generated in the background by the warmer. You don’t trigger this by hand — the chip shows progress and flips to green when done. Once written, a sidecar is permanent; you never re-embed."),
                        Step(icon: "1.circle.fill",
                             title: "Rate a seed set",
                             body: "Press 1 / 2 / 3 on each frame (unsuitable / partial / suitable). Aim for ≥ 500 frames spread across all three classes, per camera. Orthogonal R / T flags mark reflection and transitional frames."),
                        Step(icon: "command",
                             title: "Train (⌘T)",
                             body: "Fits one MLP per camera (colour + mono since 0.8.2) on all currently rated, embedded frames. ~20 s per camera on a Release build. Predictions pop up as badges on every tile."),
                        Step(icon: "brain.head.profile",
                             title: "Autopilot / Sweep — once",
                             body: "🧠 icon in the toolbar. Picks the best hyperparameters for 12 configs × 5-fold CV. Use the Colour / Mono picker to tune each camera separately. Apply the winner, it auto-retrains. Don’t run this every iteration — it’s for phase transitions only.")
                    ]
                )
                Divider()
                phaseBlock(
                    index: 2,
                    tint: .green,
                    title: "Daily loop — while you curate",
                    icon: "arrow.triangle.2.circlepath",
                    steps: [
                        Step(icon: "wand.and.stars",
                             title: "Auto-rate (⌘⇧A)",
                             body: "Streams high-confidence predictions onto unrated frames as source='auto'. Safe: never touches human labels. If nothing happens, your view is 100 % rated — ingest more or switch camera."),
                        Step(icon: "exclamationmark.triangle.fill",
                             title: "Audit mismatches",
                             body: "⚠️ icon in the toolbar. Shows only tiles where the model’s top pick disagrees with your label. Fix the genuine label mistakes; keep ambiguous ones honest (the model will learn)."),
                        Step(icon: "command",
                             title: "Train again (⌘T)",
                             body: "After every meaningful batch of new or corrected labels. ~20 s. The classifier absorbs your fixes; predictions refresh across the matrix."),
                        Step(icon: "plus.magnifyingglass",
                             title: "Targeted re-ingest",
                             body: "When class-2 or a specific sky-temp band is thin, open ⌘⇧I and use ‘Seed window from current class-2 labels’ to hunt similar frames on the NAS / Supabase.")
                    ]
                )
                Divider()
                rerunSweepBlock
                Divider()
                nuancesBlock
                Spacer(minLength: 4)
            }
            .padding(28)
        }
        .frame(minWidth: 640, idealWidth: 720,
               minHeight: 600, idealHeight: 780)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [.blue.opacity(0.85), .purple.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("How to start")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("The idiomatic workflow: ingest → embed → rate → train → sweep (once) → auto-rate / audit loop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Phase block

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private func phaseBlock(
        index: Int, tint: Color, title: String,
        icon: String, steps: [Step]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                    Text("\(index)")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(phaseSubtitle(for: index))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    stepRow(number: idx + 1, step: step, tint: tint)
                }
            }
        }
    }

    private func phaseSubtitle(for index: Int) -> String {
        switch index {
        case 1:  return "Set the foundation. Run end-to-end once; you won’t revisit every step routinely."
        case 2:  return "Fast feedback cycle. Minutes per loop, not hours."
        default: return ""
        }
    }

    private func stepRow(number: Int, step: Step, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: step.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(number).")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(step.body)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - When to re-sweep

    private var rerunSweepBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                Text("When to re-run the autopilot")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            bulletedList([
                "You’ve corrected ≥ 500 labels in an audit pass (hyperparameters shift as labels get cleaner).",
                "You toggled Night-only / Day-only or switched camera scope (each slice has its own optimum).",
                "The dataset grew by ≥ 50 %, e.g. after a class-2 hunt dropped 1 000 new frames in.",
                "Never routinely — one sweep per phase, not per loop."
            ])
        }
    }

    // MARK: - Nuances

    private var nuancesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                Text("Good to know")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            bulletedList([
                "Embed is permanent. Sidecars survive restarts, upgrades, and ⌘T runs — only a Vision-revision bump or Preferences → Advanced → Purge invalidates them.",
                "Train is cheap (~20 s). Do it often. Sweep is expensive (~1–2 min). Do it rarely.",
                "Auto-rate is non-destructive. It only touches unrated frames; your human labels are never overwritten.",
                "⌘T since 0.8.2 trains colour AND mono back-to-back. No extra click.",
                "The side panel header shows which camera’s stats it’s surfacing (COLOUR / MONO pill). Select a frame to switch.",
                "Night-only filter lives in Preferences → Training. The ‘Night’ toolbar toggle is the UI colour theme, not a content filter."
            ])
        }
    }

    private func bulletedList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { text in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Floating window controller

/// Owns the single floating "How to start" NSWindow. A standalone
/// window (not a sheet) so the user can keep it visible while
/// working the matrix — common-case is to glance at the workflow,
/// click back into ⌘T, glance again. `level = .floating` pins it
/// above the main window; re-opening brings the existing window
/// forward instead of spawning duplicates.
@MainActor
final class HowToStartWindowController {

    static let shared = HowToStartWindowController()
    private init() {}

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HowToStartView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "How to start — Allsky ML Curator"
        win.setContentSize(NSSize(width: 760, height: 820))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        // Re-home the pointer if the window is force-closed externally
        // so the next show() spawns a fresh one cleanly.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window = nil }
        }
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
