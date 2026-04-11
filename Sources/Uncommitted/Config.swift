import Foundation

struct Source: Codable, Identifiable, Hashable {
    var path: String
    var id: String { path }
}

enum ClickAction: String, Codable, CaseIterable, Hashable {
    case finder
    case vscode
    case cursor
    case xcode
    case terminal
    case iterm
    case ghostty
    case custom

    var displayName: String {
        switch self {
        case .finder:   return "Finder"
        case .vscode:   return "Visual Studio Code"
        case .cursor:   return "Cursor"
        case .xcode:    return "Xcode"
        case .terminal: return "Terminal"
        case .iterm:    return "iTerm"
        case .ghostty:  return "Ghostty"
        case .custom:   return "Custom command…"
        }
    }

    /// macOS application name passed to `open -a`, or nil for special cases.
    var openAppName: String? {
        switch self {
        case .finder, .custom: return nil
        case .vscode:          return "Visual Studio Code"
        case .cursor:          return "Cursor"
        case .xcode:           return "Xcode"
        case .terminal:        return "Terminal"
        case .iterm:           return "iTerm"
        case .ghostty:         return "Ghostty"
        }
    }
}

struct Config: Codable, Equatable {
    var sources: [Source] = []
    var clickAction: ClickAction = .finder
    var customCommand: String = "open -a Ghostty {path}"
}
