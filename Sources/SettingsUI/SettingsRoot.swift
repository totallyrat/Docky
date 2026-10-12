import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case general, appearance, interaction, nowPlaying, indicators, calendar, clock, lockScreen, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .interaction: return "Gestures & Interaction"
        case .nowPlaying: return "Now Playing"
        case .indicators: return "System Indicators"
        case .calendar: return "Calendar"
        case .clock: return "Timers, Alarms & Reminders"
        case .lockScreen: return "Lock Screen"
        case .about: return "About Docky"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .interaction: return "Gestures"
        case .indicators: return "Indicators"
        case .clock: return "Alarms & Reminders"
        case .about: return "About"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .interaction: return "hand.draw.fill"
        case .nowPlaying: return "music.note"
        case .indicators: return "speaker.wave.2.fill"
        case .calendar: return "calendar"
        case .clock: return "alarm.fill"
        case .lockScreen: return "lock.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .appearance: return .blue
        case .interaction: return .purple
        case .nowPlaying: return .pink
        case .indicators: return .teal
        case .calendar: return .red
        case .clock: return .orange
        case .lockScreen: return Color(red: 0.2, green: 0.7, blue: 0.45)
        case .about: return Color(white: 0.45)
        }
    }
}

struct PaneIcon: View {
    let pane: Pane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pane.tint.gradient)
            )
    }
}

struct SettingsRoot: View {
    @EnvironmentObject var status: IslandStatus
    @State private var selection: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Pane.allCases) { pane in
                    Label {
                        Text(pane.sidebarTitle)
                    } icon: {
                        PaneIcon(pane: pane)
                    }
                    .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 240)
            .safeAreaInset(edge: .bottom) {
                StatusFooter()
                    .padding(10)
            }
        } detail: {
            let pane = selection ?? .general
            Group {
                switch pane {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .interaction: InteractionPane()
                case .nowPlaying: NowPlayingPane()
                case .indicators: IndicatorsPane()
                case .calendar: CalendarPane()
                case .clock: ClockPane()
                case .lockScreen: LockScreenPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(pane.title)
            .transition(.opacity)
            .id(pane)
        }
        .frame(width: 800, height: 600)
        #if DOCKY_DEBUG
        .modifier(SettingsDebugReceiver(selection: $selection))
        #endif
    }
}

/// Small running / not-running indicator pinned to the bottom of the sidebar.
struct StatusFooter: View {
    @EnvironmentObject var status: IslandStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .shadow(color: status.isRunning ? .green.opacity(0.6) : .clear, radius: 3)
            Text(status.isRunning ? "Island running" : "Island not running")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if !status.isRunning {
                Button("Open") { status.launch(then: .preview) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.easeInOut(duration: 0.2), value: status.isRunning)
    }
}
