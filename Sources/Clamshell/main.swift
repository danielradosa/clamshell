import AppKit

// SwiftPM-free entry point: top-level code in main.swift is the module's `main`.
//
// Top-level code is not actor-isolated, but it does run on the main thread, so
// `assumeIsolated` is the honest way to construct the @MainActor delegate here
// rather than loosening the delegate's isolation to suit the call site.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
