import SwiftUI
import AppKit

// AppKit bridges and helper types for the panes' interactive surfaces
// (Icons/Columns/List). Split out of PaneView.swift — see its doc comments on
// "one input owner: SwiftUI or AppKit".

/// An NSMenuItem whose action is a closure (it is its own target). Context menus are
/// built by hand on NSMenu (not via NSHostingMenu, which requires macOS 14.4) — the
/// deployment target has been lowered to 13.5. Menus holding these items set
/// autoenablesItems = false, so isEnabled = true here is enough for the item to be
/// clickable.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

/// The column-width resize handle (Columns mode) — a thin strip on the border between
/// columns. AppKit rather than a SwiftUI DragGesture: a horizontal drag inside a horizontal
/// ScrollView fights with scrolling (the SwiftUI gesture captures it unreliably), whereas
/// an NSView captures the mouse itself from mouseDown to mouseUp, so dragging the border
/// doesn't scroll the list. Shows the ⟺ cursor and reports the incremental X shift
/// (event.deltaX) on every mouseDragged, plus onEnd on mouseUp.
struct ColumnResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onResize: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onBegin = onBegin
        view.onResize = onResize
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onResize = onResize
        nsView.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: (() -> Void)?
        var onResize: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        // mouseDown does NOT call super — that makes this view the owner of the drag
        // session, and all mouseDragged/mouseUp are guaranteed to come here (rather
        // than going up the responder chain).
        override func mouseDown(with event: NSEvent) {
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            onResize?(event.deltaX)
        }

        override func mouseUp(with event: NSEvent) {
            onEnd?()
        }
    }
}

/// One column in Columns mode: a directory + its contents + which child continues
/// the chain (highlighted, leads to the next column).
struct ColumnEntry: Identifiable {
    let id: URL
    let items: [FileItem]
    let selectedChildURL: URL?
}

/// Holds a weak reference to an NSView inside the Columns' horizontal ScrollView — gives
/// columnsScrollDriver access to NSView.scrollToVisible (a minimal AppKit scroll to the
/// active column) without passing the NSView itself through SwiftUI state. A reference
/// type in @State: created once per PaneView; ColumnsScrollAnchor sets .view.
final class IconScrollDriver {
    weak var view: NSView?

    func ensureVisible(_ rect: CGRect) {
        _ = view?.scrollToVisible(rect)
    }
}

/// Frames of the columns themselves in content coordinates ("columnsContent") — for
/// auto-scrolling to the active column (scrollToActiveColumn). The columns are in an
/// HStack (not lazy), so these are reliable.
struct ColumnFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// An inert AppKit anchor in the document of the Columns' horizontal ScrollView: its only
/// role is to give columnsScrollDriver a reference to an NSView whose bounds match the
/// "columnsContent" coordinate space, so that scrollToVisible(column frame) moves exactly
/// this ScrollView exactly as far as needed. It handles no events (mouseDown etc. pass on
/// down the chain), so it affects nothing but scrolling.
struct ColumnsScrollAnchor: NSViewRepresentable {
    let driver: IconScrollDriver

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        driver.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        driver.view = nsView
    }

    /// isFlipped — coordinates grow downward, as in the SwiftUI "columnsContent" space
    /// the column frames come from (otherwise scrollToVisible would get a mirrored y).
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }

        /// This NSView sits as a background inside the Columns' SwiftUI ScrollView, so its
        /// enclosingScrollView is that ScrollView's backing NSScrollView. Kill the horizontal
        /// "spring" on it: otherwise the content can be pulled sideways with a bounce (giving
        /// the impression of extra scroll) even when the columns fit entirely (bug 6).
        /// .scrollBounceBehavior would solve this at the SwiftUI level, but it's only available
        /// from macOS 14.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            enclosingScrollView?.horizontalScrollElasticity = .none
        }
    }
}

/// A text field that can take focus for itself.
///
/// Why not a SwiftUI TextField with @FocusState: the search and filter bars are opened
/// by a main-menu command, and the menu lives in AppKit; when the bar appears, first
/// responder is held by the view mode's table (FileNSTableView / IconCollectionView /
/// ColumnNSTableView), and SwiftUI focus doesn't take that responder away — the field
/// appeared unfocused and had to be clicked. Here focus is taken with the same
/// explicit `makeFirstResponder` the view modes use on themselves via their
/// focusRequestTrigger — an approach already proven in this codebase.
///
/// Esc and Return are handled by the delegate rather than SwiftUI modifiers for the
/// same reason: the field should have one event owner, not two competing ones.
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Any change of the value means "take focus".
    let focusTrigger: Int
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }

        guard context.coordinator.lastFocusTrigger != focusTrigger else { return }
        context.coordinator.lastFocusTrigger = focusTrigger
        // One runloop turn later: at call time the field isn't in the window
        // hierarchy yet, and makeFirstResponder would silently do nothing.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTextField
        var lastFocusTrigger = Int.min

        init(_ parent: FocusableTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
