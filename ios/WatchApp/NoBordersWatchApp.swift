// NoBordersWatchApp.swift — Watch app entry point.
// @main provides the _main symbol the linker requires.

import SwiftUI

@main
struct NoBordersWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}
