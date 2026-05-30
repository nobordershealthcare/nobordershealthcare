// LockScreenQRWidget.swift — WidgetKit lock screen widget.
// TARGET: NBHCWidget extension (add via Xcode: File → New → Target → Widget Extension)
//
// Displays the static QR on the lock screen — no biometric unlock required.
// Static QR only: contains physician URL only, no clinical data.
//
// PID source: App Group "group.com.noborders.shared" → UserDefaults key "patient_pid"
// Written by the main app after registration (see RegistrationView / OnboardingCoordinator).
//
// Refresh policy: once per day (static QR never expires, but we refresh for
// potential pid changes after identity re-verification).

import WidgetKit
import SwiftUI
import CoreImage

// MARK: - Inline QR rendering (widget is a separate target; can't import main app)

private func makeStaticQR(pid: String, size: CGSize) -> UIImage? {
    let base = UserDefaults(suiteName: "group.com.noborders.shared")?
        .string(forKey: "physician_base_url")
        ?? "https://physician.noborders.healthcare"
    let url  = "\(base)/p/\(pid)"
    guard let data   = url.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H",  forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let sx = size.width  / output.extent.width
    let sy = size.height / output.extent.height
    let scaled = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg)
}

// MARK: - Entry

struct QRWidgetEntry: TimelineEntry {
    let date:    Date
    let pid:     String
    let qrImage: UIImage?
}

// MARK: - Provider

struct QRTimelineProvider: TimelineProvider {

    typealias Entry = QRWidgetEntry

    func placeholder(in context: Context) -> QRWidgetEntry {
        QRWidgetEntry(date: .now, pid: "", qrImage: nil)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (QRWidgetEntry) -> Void) {
        let entry = makeEntry()
        completion(entry)
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<QRWidgetEntry>) -> Void) {
        let entry    = makeEntry()
        let nextDay  = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextDay))
        completion(timeline)
    }

    private func makeEntry() -> QRWidgetEntry {
        let pid = UserDefaults(suiteName: "group.com.noborders.shared")?
            .string(forKey: "patient_pid") ?? ""
        let image = makeStaticQR(pid: pid, size: CGSize(width: 160, height: 160))
        return QRWidgetEntry(date: .now, pid: pid, qrImage: image)
    }
}

// MARK: - Widget View

struct LockScreenQRWidgetView: View {

    let entry: QRWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangularView
        case .accessoryCircular:
            circularView
        default:
            rectangularView
        }
    }

    private var rectangularView: some View {
        HStack(spacing: 8) {
            qrView
            VStack(alignment: .leading, spacing: 2) {
                Text("EMERGENCY QR")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Text("Scan for medical data")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .padding(4)
    }

    private var circularView: some View {
        qrView
            .padding(4)
    }

    private var qrView: some View {
        Group {
            if let img = entry.qrImage {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.title)
            }
        }
    }
}

// MARK: - Widget Configuration

struct LockScreenQRWidget: Widget {

    let kind = "com.noborders.widget.lockscreen.qr"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QRTimelineProvider()) { entry in
            LockScreenQRWidgetView(entry: entry)
        }
        .configurationDisplayName("Emergency QR")
        .description("Static QR code for emergency access — always visible on lock screen.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
        ])
    }
}

// MARK: - Widget Bundle (main entry point for the extension target)

@main
struct NBHCWidgetBundle: WidgetBundle {
    var body: some Widget {
        LockScreenQRWidget()
    }
}
