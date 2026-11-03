import AppKit

// `windowkeeper <command>` (the app binary under a short name): run it against the running app
// and exit, without starting a second copy. See Agent/AgentCLI.swift.
if let code = AgentCLI.runIfRequested() { exit(code) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // A menu bar app; it has a Dock icon only if the user turned one on. An agent CLI test
    // copy never shows one (the Dock setting it would read is the installed app's).
    app.setActivationPolicy(AppPresence.showInDock && !AgentSocket.isTestRun ? .regular : .accessory)
    withExtendedLifetime(delegate) { app.run() }
}
