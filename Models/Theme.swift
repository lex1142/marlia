import AppKit
import SwiftUI

/// The app's color theme.
///
/// `system` is exactly how the app looked before themes existed: no color is replaced,
/// everything comes from macOS (including automatic light/dark switching). The rest are
/// fixed palettes of well-known editor/terminal themes. `solarizedAuto` is a pair: light
/// with the light system appearance, dark with the dark one.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dracula
    case gruvboxDark
    case nord
    case solarizedDark
    case solarizedLight
    case solarizedAuto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .dracula: return "Dracula"
        case .gruvboxDark: return "Gruvbox Dark"
        case .nord: return "Nord"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .solarizedAuto: return "Solarized (Auto)"
        }
    }

    /// A theme with a fixed palette has to impose its own lightness: otherwise the
    /// system parts of the UI (menus, sheets, toolbar, scrollers, text fields) stay
    /// light on top of dark panes — and vice versa. nil = "don't impose", the system
    /// decides: that's how both `system` and `solarizedAuto` work (the latter precisely
    /// follows the system).
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system, .solarizedAuto: return nil
        case .dracula, .gruvboxDark, .nord, .solarizedDark: return NSAppearance(named: .darkAqua)
        case .solarizedLight: return NSAppearance(named: .aqua)
        }
    }

    /// Whether the theme's palette changes with the system light/dark switch. For such
    /// themes ThemeStore subscribes to appearance changes and triggers a redraw (see its
    /// init).
    var followsSystemAppearance: Bool {
        switch self {
        case .system, .solarizedAuto: return true
        default: return false
        }
    }

    @MainActor
    var palette: ThemePalette {
        switch self {
        case .system: return .system
        case .dracula: return .dracula
        case .gruvboxDark: return .gruvboxDark
        case .nord: return .nord
        case .solarizedDark: return .solarizedDark
        case .solarizedLight: return .solarizedLight
        // The only theme whose palette isn't a constant: look at the app's effective
        // appearance (not the system's UserDefaults) — it accounts for both the scheduled
        // "Auto" and a manual switch in System Settings.
        case .solarizedAuto:
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .solarizedDark : .solarizedLight
        }
    }
}

/// A theme's set of colors. Optional fields mean "the theme doesn't paint this
/// background" — that way the system theme doesn't change a single pixel: the
/// view stays exactly as it was (see `themedBackground` and `??
/// defaultTableBackground` in the AppKit modes).
struct ThemePalette {
    /// Background of the file area (list/icons/columns).
    let paneBackground: NSColor?
    /// Background of the pane's "chrome": path bar, search, status bar.
    let chromeBackground: NSColor?
    let sidebarBackground: NSColor?
    let windowBackground: NSColor?
    let label: NSColor
    let secondaryLabel: NSColor
    /// Background of a selected row/cell. Drawn by hand only when `isCustom` —
    /// otherwise AppKit draws the highlight entirely (see ThemedTableRowView).
    let selection: NSColor
    let accent: NSColor
    let separator: NSColor
    /// Background of the inline rename field.
    let fieldBackground: NSColor
    let error: NSColor
    /// Whether the theme sets its own colors at all. false only for `system`.
    let isCustom: Bool

    /// Icon color on top of an accent fill (the selected segment of the view-mode
    /// switcher). Computed from the accent's own luminance rather than set by hand in
    /// each palette: Dracula/Gruvbox/Nord have a light accent that needs a dark icon,
    /// Solarized has a saturated blue that needs a light one.
    var onAccent: NSColor {
        let c = accent.usingColorSpace(.sRGB) ?? accent
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        return luminance > 0.35 ? (paneBackground ?? .textBackgroundColor) : label
    }

    static let system = ThemePalette(
        paneBackground: nil,
        chromeBackground: nil,
        sidebarBackground: nil,
        windowBackground: nil,
        label: .labelColor,
        secondaryLabel: .secondaryLabelColor,
        selection: .selectedContentBackgroundColor,
        accent: .controlAccentColor,
        separator: .separatorColor,
        fieldBackground: .textBackgroundColor,
        error: .systemRed,
        isCustom: false
    )

    /// Canonical Dracula colors: Background #282A36, Darker Background #21222C, Selection
    /// #44475A, Foreground #F8F8F2, Comment #6272A4, Purple #BD93F9, Red #FF5555.
    ///
    /// The one deviation is secondary text (size/kind/dates, labels): the canonical Comment
    /// #6272A4 on #282A36 gives ~2.4:1 contrast, i.e. the date columns would read poorly.
    /// Instead the main text color with transparency is used — the same hue as file names,
    /// but muted (~4.5:1). Comment stays where it's meant as "utility graphics": chevrons
    /// and separators.
    static let dracula = ThemePalette(
        paneBackground: NSColor(srgbRed: 0x28 / 255, green: 0x2A / 255, blue: 0x36 / 255, alpha: 1),
        chromeBackground: NSColor(srgbRed: 0x21 / 255, green: 0x22 / 255, blue: 0x2C / 255, alpha: 1),
        sidebarBackground: NSColor(srgbRed: 0x21 / 255, green: 0x22 / 255, blue: 0x2C / 255, alpha: 1),
        windowBackground: NSColor(srgbRed: 0x21 / 255, green: 0x22 / 255, blue: 0x2C / 255, alpha: 1),
        label: NSColor(srgbRed: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF2 / 255, alpha: 1),
        secondaryLabel: NSColor(srgbRed: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF2 / 255, alpha: 0.62),
        selection: NSColor(srgbRed: 0x44 / 255, green: 0x47 / 255, blue: 0x5A / 255, alpha: 1),
        accent: NSColor(srgbRed: 0xBD / 255, green: 0x93 / 255, blue: 0xF9 / 255, alpha: 1),
        separator: NSColor(srgbRed: 0x62 / 255, green: 0x72 / 255, blue: 0xA4 / 255, alpha: 0.45),
        fieldBackground: NSColor(srgbRed: 0x1E / 255, green: 0x1F / 255, blue: 0x29 / 255, alpha: 1),
        error: NSColor(srgbRed: 0xFF / 255, green: 0x55 / 255, blue: 0x55 / 255, alpha: 1),
        isCustom: true
    )

    /// Gruvbox Dark (github.com/morhetz/gruvbox) — warm, unlike the cool Dracula/Nord.
    /// Pane background bg0 #282828, chrome is the "hard" background variant bg0_h
    /// #1D2021, text fg1 #EBDBB2, selection bg2 #504945, accent the signature orange
    /// #FE8019. Here secondary text is canonical (gray #A89984): unlike Dracula, it
    /// gives ~5.3:1 on its background and needs no adjustment.
    static let gruvboxDark = ThemePalette(
        paneBackground: srgb(0x282828),
        chromeBackground: srgb(0x1D2021),
        sidebarBackground: srgb(0x1D2021),
        windowBackground: srgb(0x1D2021),
        label: srgb(0xEBDBB2),
        secondaryLabel: srgb(0xA89984),
        selection: srgb(0x504945),
        accent: srgb(0xFE8019),
        separator: srgb(0x665C54, alpha: 0.7),
        fieldBackground: srgb(0x1D2021),
        error: srgb(0xFB4934),
        isCustom: true
    )

    /// Nord (nordtheme.com). The only one of our themes where the chrome is LIGHTER than
    /// the pane rather than darker: in Nord's "Polar Night" nord0 #2E3440 is the darkest
    /// color, there's nothing darker, and its own reference implementations (editors)
    /// paint the sidebar nord1 #3B4252. Secondary text is as in Dracula, the main color
    /// with transparency: the canonical nord3 #4C566A gives ~1.9:1 on the pane
    /// background, and the "comment" #616E88 from nord-vscode ~2.4:1, i.e. the date
    /// columns would be unreadable.
    static let nord = ThemePalette(
        paneBackground: srgb(0x2E3440),
        chromeBackground: srgb(0x3B4252),
        sidebarBackground: srgb(0x3B4252),
        windowBackground: srgb(0x3B4252),
        label: srgb(0xD8DEE9),
        secondaryLabel: srgb(0xD8DEE9, alpha: 0.62),
        selection: srgb(0x434C5E),
        accent: srgb(0x88C0D0),
        separator: srgb(0x4C566A),
        fieldBackground: srgb(0x2E3440),
        error: srgb(0xBF616A),
        isCustom: true
    )

    /// Solarized Dark (ethanschoonover.com/solarized) — a mirror of the light pair, with
    /// roles assigned symmetrically: text base2 #EEE8D5, secondary base1 #93A1A1
    /// (base02/base01 in the light one). This is NOT the spec's "body text" (base0/base00
    /// there): Solarized is deliberately low-contrast, and the base text doesn't hold up as
    /// a file name — it fails readability on a selected row (3.6:1 versus 7.8:1 for the
    /// chosen one). The reason for the constraint is our architecture: text color doesn't
    /// depend on whether the row is selected — otherwise cells would have to be
    /// reconfigured on every arrow step (the very "jelly" we moved away from), so one color
    /// must read on both the pane background and the selection.
    ///
    /// Selection is the signature blue #268BD2 with transparency: the canonical base02 is
    /// almost indistinguishable from the pane background (editors use it to highlight the
    /// current line, which isn't enough for a selected file).
    static let solarizedDark = ThemePalette(
        paneBackground: srgb(0x002B36),
        chromeBackground: srgb(0x073642),
        sidebarBackground: srgb(0x073642),
        windowBackground: srgb(0x073642),
        label: srgb(0xEEE8D5),
        secondaryLabel: srgb(0x93A1A1),
        selection: srgb(0x268BD2, alpha: 0.40),
        accent: srgb(0x268BD2),
        separator: srgb(0x586E75, alpha: 0.6),
        fieldBackground: srgb(0x073642),
        error: srgb(0xDC322F),
        isCustom: true
    )

    /// Solarized Light — a mirror of the dark one: background base3 #FDF6E3, chrome
    /// base2 #EEE8D5, text base02 #073642, secondary base01 #586E75 (on the choice of
    /// roles see solarizedDark).
    static let solarizedLight = ThemePalette(
        paneBackground: srgb(0xFDF6E3),
        chromeBackground: srgb(0xEEE8D5),
        sidebarBackground: srgb(0xEEE8D5),
        windowBackground: srgb(0xEEE8D5),
        label: srgb(0x073642),
        secondaryLabel: srgb(0x586E75),
        selection: srgb(0x268BD2, alpha: 0.35),
        accent: srgb(0x268BD2),
        separator: srgb(0x93A1A1, alpha: 0.6),
        fieldBackground: srgb(0xFDF6E3),
        error: srgb(0xDC322F),
        isCustom: true
    )

    /// A color from a HEX constant — so palettes read one to one against the
    /// themes' websites.
    private static func srgb(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

/// The selected theme — one for the app (like WorkspaceStore/FileClipboard), not per
/// window or tab: appearance is a property of the app. Stored in UserDefaults.
///
/// `generation` counts theme changes. The AppKit modes (List/Icons/Columns) need it:
/// their `updateNSView` deliberately reconfigures visible cells only when something
/// affecting their look has changed (zoom, the set of cut items), otherwise arrow
/// navigation would be bogged down by reconfiguration on every step. The theme is one
/// more such signal, and comparing an integer counter is cheaper than comparing a set
/// of colors.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    private static let defaultsKey = "Marlia.theme"

    @Published private(set) var theme: AppTheme
    @Published private(set) var generation = 0

    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        theme = AppTheme(rawValue: stored) ?? .system
        // The system light/dark switch: for Solarized (Auto) the whole palette depends on
        // it, and the palette returns static colors — so a redraw has to be requested
        // explicitly (bump generation), otherwise the panes keep the old colors until some
        // other update. We observe the app's effectiveAppearance rather than the system
        // setting: it accounts for both the "Auto" schedule and a manual switch.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.theme.followsSystemAppearance else { return }
                self.generation += 1
            }
        }
    }

    var palette: ThemePalette { theme.palette }

    func set(_ newTheme: AppTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        generation += 1
        UserDefaults.standard.set(newTheme.rawValue, forKey: Self.defaultsKey)
        applyToApp()
    }

    /// Parts of the appearance that live outside the SwiftUI tree: the app's overall
    /// appearance (menus, sheets, toolbar, scrollers) and the background of
    /// already-open windows. Called at launch and on every theme change.
    func applyToApp() {
        NSApp.appearance = theme.appKitAppearance
        for window in NSApp.windows { apply(to: window) }
    }

    /// Window background: visible in the title/toolbar area and during resizing, before
    /// SwiftUI redraws the content. Without it dark panes are surrounded by a light
    /// frame.
    func apply(to window: NSWindow) {
        window.backgroundColor = palette.windowBackground ?? .windowBackgroundColor
    }
}

/// Shorthand access to the palette from drawing code (table/collection cells,
/// rows).
@MainActor
enum Theme {
    static var current: ThemePalette { ThemeStore.shared.palette }
}

extension View {
    /// Paints the background only if the theme actually set a color. In the system
    /// theme every background is nil, so the view is returned untouched — the guarantee
    /// that "System" looks exactly like the app did before themes existed.
    @ViewBuilder
    func themedBackground(_ color: NSColor?) -> some View {
        if let color {
            background(Color(nsColor: color))
        } else {
            self
        }
    }

    /// The theme accent for SwiftUI system controls — toggle buttons (hidden files,
    /// regexp), checkboxes, the sidebar row selection, progress indicators. Without it
    /// they're painted with the accent color from the user's SYSTEM settings (pink for
    /// some, green for others) and look out of place in any theme.
    ///
    /// This does NOT extend to the segmented view-mode switcher — see themedViewModePicker
    /// in PaneView: it draws itself.
    @ViewBuilder
    func themedTint(_ palette: ThemePalette) -> some View {
        if palette.isCustom {
            tint(Color(nsColor: palette.accent))
        } else {
            self
        }
    }

    /// The same for the List in the sidebar: painting the background isn't enough — the
    /// list's system backdrop has to be removed too, otherwise it's drawn on top (with
    /// .listStyle(.sidebar) it has vibrancy).
    @ViewBuilder
    func themedSidebarBackground(_ color: NSColor?) -> some View {
        if let color {
            scrollContentBackground(.hidden).background(Color(nsColor: color))
        } else {
            self
        }
    }
}

/// A column header drawn in theme colors.
///
/// An NSTableView header can't be painted from outside: both the background and the text
/// are drawn by `NSTableHeaderCell` itself in system colors (in the dark appearance its own
/// grey, noticeably lighter than our panes). So the background/separator are drawn by us,
/// while the text and sort indicator are left to AppKit: it draws the indicator in a
/// separate call (`drawSortIndicator`) and our `draw` doesn't cancel it — verified by
/// rendering the header offscreen.
final class ThemedTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let palette = Theme.current
        guard palette.isCustom, let background = palette.chromeBackground else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        background.setFill()
        cellFrame.fill()
        palette.separator.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 3, width: 1, height: cellFrame.height - 6).fill()
        // A 4pt inset — the same as the system drawing gives: without it the title
        // shifts left relative to the row text (checked by rendering both variants
        // offscreen).
        drawInterior(withFrame: cellFrame.insetBy(dx: 4, dy: 0), in: controlView)
    }
}

/// The table header: also paints what isn't covered by column headers (the strip to the
/// right of the last column) — the cells themselves don't reach there.
final class ThemedTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        if let background = Theme.current.chromeBackground {
            background.setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }
}

/// A table row that draws the selection in the theme color.
///
/// NSTableView's native highlight uses the system accent color and can't be configured
/// via a property — so for a theme with its own palette we draw it ourselves. In the
/// system theme (`isCustom == false`) drawing is left entirely to AppKit, so as not to
/// lose its vibrancy and the "inactive window — muted selection" behavior.
final class ThemedTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let palette = Theme.current
        guard palette.isCustom, selectionHighlightStyle != .none else {
            super.drawSelection(in: dirtyRect)
            return
        }
        // isEmphasized == window/table has focus. An inactive pane mutes its selection —
        // the same meaning as the system behavior, otherwise both panes look active.
        (isEmphasized ? palette.selection : palette.selection.withAlphaComponent(0.55)).setFill()
        dirtyRect.fill()
    }
}
