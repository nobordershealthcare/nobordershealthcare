//
//  nobordershealthcare_appApp.swift
//  nobordershealthcare-app
//

import SwiftUI

@main
struct nobordershealthcare_appApp: App {

    // Single NWPathMonitor instance for the secondary-tab status chips.
    @StateObject private var networkMonitor = NetworkMonitor()

    // User-facing colour-scheme preference (mirrors ProfileView's @AppStorage).
    // "auto" → nil → follows iOS system.  "light"/"dark" → override.
    @AppStorage("colorScheme") private var schemePref: String = "auto"

    private var resolvedScheme: ColorScheme? {
        switch schemePref {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // .preferredColorScheme(nil) = follow system
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(networkMonitor)
                .preferredColorScheme(resolvedScheme)
        }
    }
}
