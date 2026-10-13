import AppKit

// AppKit entry point (not a SwiftUI App/Scene): we own the windows/tabs/menu ourselves so
// SwiftUI scenes can't overwrite NSApp.mainMenu or break tabs (see WindowControllers.swift
// and MarliaWindowController). The window content itself is still SwiftUI (hosted root
// views).
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
