// Lock screen + home screen widget displaying the emergency QR.
// Reads ScopedJWT from the shared App Group Keychain — no device unlock required.
// Never re-signs tokens; never accesses private keys.
// Shows expiry countdown and a red border when < 2 minutes remain.

import WidgetKit
import SwiftUI
import Security
import CoreImage

// MARK: - Timeline entry

struct EmergencyEntry: TimelineEntry {
    let date: Date
    let qrImage: Image?
    let expiresAt: Date?
    let isExpired: Bool
}

// MARK: - Timeline provider

struct EmergencyProvider: TimelineProvider {

    private let appGroupID       = "group.com.noborders.emergency"
    private let tokenKeychainKey = "com.noborders.token.scoped-jwt"

    func placeholder(in context: Context) -> EmergencyEntry {
        EmergencyEntry(date: .now, qrImage: nil, expiresAt: nil, isExpired: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (EmergencyEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EmergencyEntry>) -> Void) {
        let entry = makeEntry()
        // Refresh every 60 seconds to update the countdown; WidgetKit may coalesce these.
        let nextRefresh = Calendar.current.date(byAdding: .second, value: 60, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry() -> EmergencyEntry {
        guard let token = loadToken() else {
            return EmergencyEntry(date: .now, qrImage: nil, expiresAt: nil, isExpired: true)
        }
        let isExpired = token.expiresAt < .now
        let qrImage = isExpired ? nil : renderQR(from: token.rawToken)
        return EmergencyEntry(date: .now, qrImage: qrImage, expiresAt: token.expiresAt, isExpired: isExpired)
    }

    private func loadToken() -> WidgetScopedJWT? {
        let q: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      tokenKeychainKey,
            kSecAttrAccessGroup as String:  appGroupID,
            kSecReturnData as String:       true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(WidgetScopedJWT.self, from: data)
    }

    private func renderQR(from rawToken: String) -> Image? {
        guard let data = rawToken.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let size = CGFloat(200)
        let sx = size / output.extent.width
        let sy = size / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}

// MARK: - Minimal token type (widget-side, no dependency on main app module)

private struct WidgetScopedJWT: Decodable {
    let rawToken: String
    let expiresAt: Date
    let jti: String
}

// MARK: - Widget views

struct EmergencyWidgetEntryView: View {
    let entry: EmergencyEntry
    @Environment(\.widgetFamily) private var family

    private var secondsLeft: Int {
        Int((entry.expiresAt ?? .now).timeIntervalSinceNow)
    }

    private var isWarningSoon: Bool { secondsLeft > 0 && secondsLeft < 120 }

    var body: some View {
        if entry.isExpired || entry.qrImage == nil {
            expiredView
        } else {
            qrView
        }
    }

    private var qrView: some View {
        ZStack {
            Color.white
            VStack(spacing: 4) {
                entry.qrImage!
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)

                countdownBadge
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isWarningSoon ? Color.red : Color.clear, lineWidth: 3)
        )
    }

    private var expiredView: some View {
        ZStack {
            Color(white: 0.95)
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("QR Expired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Open app to refresh")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var countdownBadge: some View {
        let s = max(0, secondsLeft)
        let text = String(format: "%d:%02d", s / 60, s % 60)
        return Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(isWarningSoon ? .red : .secondary)
            .padding(.bottom, 2)
    }
}

// MARK: - Widget declaration

struct EmergencyWidget: Widget {
    let kind = "EmergencyQR"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EmergencyProvider()) { entry in
            EmergencyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Emergency QR")
        .description("Displays your emergency medical QR code.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall, .systemMedium])
    }
}
