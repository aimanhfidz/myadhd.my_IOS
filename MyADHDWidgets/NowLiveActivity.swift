/* ============================================================
   MyADHDWidgets/NowLiveActivity.swift — the Now card, on the lock screen

   The model, the two intents and why there is no timer are in
   Shared/NowActivity.swift. This is only the drawing: the lock-screen
   card, and the Dynamic Island's three sizes.

   Brand: `--surface` ground and Baloo, like the tiles (BRAND.md §11.4).
   Orange appears once, as the dot beside "Late", and only when the task
   is late (§3.3). Done is the accent; Not now is an edge.
   ============================================================ */

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct NowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowActivityAttributes.self) { context in
            NowLockCard(state: context.state)
                .activityBackgroundTint(Color("WidgetBackground"))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string: "myadhd://open"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Capsule().fill(NowInk.violet).frame(width: 9, height: 14)
                        Text("Now")
                            .font(.baloo(13, .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.late { LateMark().padding(.trailing, 4) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title)
                            .font(.baloo(19, .heavy))
                            .lineLimit(context.state.firstStep.isEmpty ? 2 : 1)
                        if !context.state.firstStep.isEmpty {
                            FirstStep(text: context.state.firstStep, island: true)
                        }
                        Button(intent: NowDoneIntent(id: context.state.id)) {
                            Text("Done")
                                .font(.baloo(15, .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(NowInk.accentNight)
                        .foregroundStyle(NowInk.onAccentNight)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Capsule().fill(NowInk.violet).frame(width: 9, height: 14)
            } compactTrailing: {
                Text(context.state.title)
                    .font(.baloo(13, .bold))
                    .lineLimit(1)
                    .frame(maxWidth: 76)
            } minimal: {
                Capsule().fill(NowInk.violet).frame(width: 9, height: 14)
            }
            .widgetURL(URL(string: "myadhd://open"))
        }
    }
}

// MARK: - the lock screen card

private struct NowLockCard: View {
    @Environment(\.colorScheme) private var scheme
    let state: NowActivityAttributes.ContentState

    /* iOS gives the lock-screen card 160 points and crops the rest from
       the top, so this is laid out to a budget: a one-line title when
       there is a first step under it, two when there is not, and 34-point
       buttons rather than the system's taller bordered ones. */
    private var hasStep: Bool { !state.firstStep.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                Text("my").font(.baloo(13, .heavy))
                Text(".adhd").font(.baloo(13, .heavy)).foregroundStyle(NowInk.violet)
                Spacer(minLength: 8)
                if state.late {
                    LateMark()
                } else {
                    Text("Now").font(.baloo(12.5, .bold)).foregroundStyle(.secondary)
                }
            }

            Text(state.title)
                .font(.baloo(19, .heavy))
                .lineLimit(hasStep ? 1 : 2)

            if hasStep {
                FirstStep(text: state.firstStep, island: false)
            }

            HStack(spacing: 8) {
                Button(intent: NowDoneIntent(id: state.id)) {
                    Text("Done")
                        .font(.baloo(15, .bold))
                        .foregroundStyle(scheme == .dark ? NowInk.onAccentNight : Color.white)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(CategoryTint.accent(scheme), in: Capsule())
                }
                .buttonStyle(.plain)

                Button(intent: NowSkipIntent(id: state.id)) {
                    Text("Not now")
                        .font(.baloo(15, .bold))
                        .foregroundStyle(CategoryTint.accent(scheme))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 34)
                        .overlay(Capsule().strokeBorder(CategoryTint.accent(scheme), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - parts

private struct FirstStep: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let island: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Start here — 2 minutes")
                .font(.baloo(11.5, .bold))
                .foregroundStyle(island ? NowInk.accentNight : CategoryTint.accent(scheme))
            Text(text)
                .font(.baloo(13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The one orange thing: a dot, and the word in ink beside it. Orange as
/// text on a light ground is never allowed (BRAND.md §3.3).
private struct LateMark: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(CategoryTint.urgent).frame(width: 7, height: 7)
            Text("Late").font(.baloo(12.5, .bold))
        }
    }
}

/// The two brand values this file needs that CategoryTint does not carry.
private enum NowInk {
    /// `logo-violet` — the ".adhd" of the wordmark, never re-tinted.
    static let violet = Color(red: 123 / 255, green: 63 / 255, blue: 228 / 255)
    /// `--accent` at night. The Dynamic Island is always black.
    static let accentNight = Color(red: 139 / 255, green: 125 / 255, blue: 255 / 255)
    /// `onAccent` at night: the ink on that accent.
    static let onAccentNight = Color(red: 16 / 255, green: 16 / 255, blue: 24 / 255)
}
