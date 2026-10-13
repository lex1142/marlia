import AppKit
import Foundation

/// A snapshot of one window/tab — both panes: path + view mode.
struct WindowState: Codable {
    var leftPath: String
    var leftViewMode: String
    var rightPath: String
    var rightViewMode: String
    var showSecondPane: Bool = true
    var showInspector: Bool = false
    /// Window frame (NSStringFromRect). Empty means default position/size. The
    /// SwiftUI scene used to save this itself; since moving to AppKit windows we
    /// store it ourselves.
    var frame: String = ""

    enum CodingKeys: String, CodingKey {
        case leftPath, leftViewMode, rightPath, rightViewMode, showSecondPane, showInspector, frame
    }

    init(leftPath: String, leftViewMode: String, rightPath: String, rightViewMode: String, showSecondPane: Bool = true, showInspector: Bool = false, frame: String = "") {
        self.leftPath = leftPath
        self.leftViewMode = leftViewMode
        self.rightPath = rightPath
        self.rightViewMode = rightViewMode
        self.showSecondPane = showSecondPane
        self.showInspector = showInspector
        self.frame = frame
    }

    /// showSecondPane/frame were added later — sessions saved before that have no such keys
    /// in their JSON, hence decodeIfPresent with a default instead of the plain throwing
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leftPath = try container.decode(String.self, forKey: .leftPath)
        leftViewMode = try container.decode(String.self, forKey: .leftViewMode)
        rightPath = try container.decode(String.self, forKey: .rightPath)
        rightViewMode = try container.decode(String.self, forKey: .rightViewMode)
        showSecondPane = try container.decodeIfPresent(Bool.self, forKey: .showSecondPane) ?? true
        showInspector = try container.decodeIfPresent(Bool.self, forKey: .showInspector) ?? false
        frame = try container.decodeIfPresent(String.self, forKey: .frame) ?? ""
    }
}

/// Persists the list of open windows between launches (⌘Q saves, the next
/// launch restores — one window/tab per saved state).
enum WindowStateStore {
    private static let defaultsKey = "Marlia.LastSession"

    static func save(_ states: [WindowState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func load() -> [WindowState] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let states = try? JSONDecoder().decode([WindowState].self, from: data) else {
            return []
        }
        return states
    }
}

/// Weak references to every live AppState (one per window) — needed on quit to
/// collect the state of each open window for saving.
enum AppStateRegistry {
    private final class WeakBox {
        weak var value: AppState?
        init(_ value: AppState) { self.value = value }
    }

    private static var boxes: [WeakBox] = []

    static func register(_ appState: AppState) {
        boxes.append(WeakBox(appState))
    }

    static var liveStates: [AppState] {
        boxes.compactMap(\.value)
    }

    /// The AppState of the window that currently has focus. The main-menu items need it: the
    /// menu lives in AppKit and has no SwiftUI @FocusedValue mechanism, which the commands
    /// used before. The window is assigned to its AppState by WindowTabConfigurator
    /// (viewDidMoveToWindow).
    @MainActor
    static var activeState: AppState? {
        let candidates = liveStates
        if let key = NSApp.keyWindow, let state = candidates.first(where: { $0.window === key }) {
            return state
        }
        // keyWindow can be nil (e.g. a sheet/panel is open) — then fall back to
        // the main window.
        if let main = NSApp.mainWindow, let state = candidates.first(where: { $0.window === main }) {
            return state
        }
        return candidates.first
    }
}

