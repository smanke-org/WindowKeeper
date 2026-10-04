import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // A menu bar app; it has a Dock icon only if the user turned one on.
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    withExtendedLifetime(delegate) { app.run() }
}
