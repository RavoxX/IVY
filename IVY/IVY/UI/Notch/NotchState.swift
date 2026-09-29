import AppKit
import Combine
import IVYCore
import SwiftUI

/// What the notch is showing.
enum NotchMode: Equatable {
    /// Hidden behind the physical notch (optionally with the music live activity).
    case closed
    /// Hover dashboard (media player, file shelf, history) — opened by hovering the notch.
    case dashboard
    /// IVY assistant (listening, typing, answering).
    case assistant
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case home, shelf, history
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .history: return "clock.fill"
        }
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .shelf: return "Shelf"
        case .history: return "History"
        }
    }
}

/// Assistant sub-state. Together with the gesture machine's states this realizes the
/// spec's idle → listening/textInput → transcribing → thinking → executing → responding
/// → speaking flow; `error` and `confirming` can occur along the way.
enum AssistantPhase: Equatable {
    case listening
    case textInput
    case transcribing
    case loadingModel
    case thinking
    case executing(String)
    case responding
    case confirming
    case answered
    case speaking
    case error(String)

    var isBusy: Bool {
        switch self {
        case .transcribing, .loadingModel, .thinking, .executing, .responding: return true
        default: return false
        }
    }
}

/// Layout constants for the notch panel.
enum NotchLayout {
    static let assistantWidth: CGFloat = 392
    static let musicAssistantWidth: CGFloat = 360
    static let dashboardWidth: CGFloat = 600
    static let dashboardBodyHeight: CGFloat = 150
    static let maxAssistantBody: CGFloat = 520
    static let liveActivityWing: CGFloat = 36
    static let shadowMargin: CGFloat = 28
    static let openTopRadius: CGFloat = 10
    static let openBottomRadius: CGFloat = 26
}
