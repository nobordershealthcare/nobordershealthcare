// QRGeneratorView.swift — Phase 4: live emergency QR display.
//
// Binds to EmergencyCardService (@MainActor ObservableObject).
// Features:
//   • QR generated via CIQRCodeGenerator (error correction level H — 30%)
//   • nobordershealthcare logo mark composited in QR centre
//   • Countdown ring drawn with Canvas.addArc — turns red at < 120 s
//   • Red pulse animation at < 120 s (opacity animation on the warning icon)
//   • "Refresh" button — calls EmergencyCardService.forceRefresh() (biometric-gated)
//   • "Share" button — UIActivityViewController sheet with QR UIImage
//
// No hardcoded patient data. Content driven entirely by EmergencyCardService.tokenState.

import SwiftUI
import CoreImage

struct QRGeneratorView: View {

    @StateObject private var service = EmergencyCardService.shared

    @State private var qrImage: UIImage?
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var showShareSheet = false
    @State private var pulseOpacity: Double = 1.0

    // MARK: - Derived state helpers

    private var currentJWT: String? {
        switch service.tokenState {
        case .valid(let j, _), .expiring(let j, _): return j
        default: return nil
        }
    }

    private var secondsRemaining: Int? {
        switch service.tokenState {
        case .valid(_, let t):    return Int(t)
        case .expiring(_, let s): return s
        default: return nil
        }
    }

    private var isExpiringSoon: Bool {
        if case .expiring = service.tokenState { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    statusBanner
                    qrSection
                    if secondsRemaining != nil { countdownRing }
                    actionButtons
                    legalDisclaimer
                }
                .padding(20)
            }
            .navigationTitle("Emergency QR")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await service.refreshIfNeeded()
        }
        .onChange(of: service.tokenState) { _, newState in
            switch newState {
            case .valid(let j, _), .expiring(let j, _):
                qrImage = generateQR(from: j)
            case .expired, .missing:
                qrImage = nil
            }
        }
        .onAppear {
            if let j = currentJWT, qrImage == nil {
                qrImage = generateQR(from: j)
            }
        }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIconName)
                .foregroundStyle(statusColor)
                .font(.title2)
                .opacity(isExpiringSoon ? pulseOpacity : 1.0)
                .animation(
                    isExpiringSoon
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: pulseOpacity
                )
                .onChange(of: isExpiringSoon) { _, soon in
                    pulseOpacity = soon ? 0.2 : 1.0
                }
                .onAppear {
                    if isExpiringSoon { pulseOpacity = 0.2 }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).fontWeight(.semibold)
                Text(statusSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch service.tokenState {
        case .valid:    return .green
        case .expiring: return .red
        case .expired:  return .orange
        case .missing:  return Color(.systemGray3)
        }
    }

    private var statusIconName: String {
        switch service.tokenState {
        case .valid:    return "checkmark.shield.fill"
        case .expiring: return "exclamationmark.triangle.fill"
        case .expired:  return "xmark.circle.fill"
        case .missing:  return "qrcode"
        }
    }

    private var statusTitle: String {
        switch service.tokenState {
        case .valid:    return "QR Active"
        case .expiring: return "Expiring Soon"
        case .expired:  return "QR Expired"
        case .missing:  return "No QR Available"
        }
    }

    private var statusSubtitle: String {
        switch service.tokenState {
        case .valid(_, let t):    return "Valid for \(formatDuration(Int(t)))"
        case .expiring(_, let s): return "Expires in \(s) s — tap Refresh"
        case .expired:            return "Tap Refresh to re-sign with biometrics"
        case .missing:            return "Complete emergency card setup first"
        }
    }

    // MARK: - QR section

    private var qrSection: some View {
        ZStack {
            if let img = qrImage {
                compositeQR(img)
            } else {
                placeholderQR
            }
        }
    }

    private func compositeQR(_ img: UIImage) -> some View {
        ZStack {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // Red pulsing overlay when expiring
                .opacity(isExpiringSoon ? 0.72 : 1.0)
                .animation(
                    isExpiringSoon
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isExpiringSoon
                )

            // Logo mark composited in QR centre
            Circle()
                .fill(.white)
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "cross.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.navy)
                }
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
    }

    private var placeholderQR: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.systemGray6))
            .frame(width: 280, height: 280)
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 64))
                        .foregroundStyle(Color(.systemGray3))
                    if isRefreshing {
                        ProgressView()
                    } else if case .missing = service.tokenState {
                        Text("Complete emergency card\nsetup to generate a QR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
    }

    // MARK: - Countdown ring

    private var countdownRing: some View {
        VStack(spacing: 8) {
            ZStack {
                Canvas { ctx, size in
                    drawRing(ctx: ctx, size: size)
                }
                .frame(width: 80, height: 80)

                countdownLabel
            }

            Text("Auto-refreshes every 15 minutes")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func drawRing(ctx: GraphicsContext, size: CGSize) {
        guard let secs = secondsRemaining else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 5
        let total: Double = 900   // 15 min = 900 s
        let fraction = max(0, min(1, Double(secs) / total))
        let startAngle = Angle.degrees(-90)
        let fillColor: GraphicsContext.Shading = secs < 120
            ? .color(.red)
            : .color(.green)

        // Background track
        var track = Path()
        track.addArc(center: centre, radius: radius,
                     startAngle: startAngle, endAngle: .degrees(270),
                     clockwise: false)
        ctx.stroke(track,
                   with: .color(Color(.systemGray5)),
                   style: StrokeStyle(lineWidth: 7, lineCap: .round))

        // Progress arc
        guard fraction > 0 else { return }
        var arc = Path()
        arc.addArc(center: centre, radius: radius,
                   startAngle: startAngle,
                   endAngle: .degrees(-90 + fraction * 360),
                   clockwise: false)
        ctx.stroke(arc,
                   with: fillColor,
                   style: StrokeStyle(lineWidth: 7, lineCap: .round))
    }

    private var countdownLabel: some View {
        VStack(spacing: 0) {
            Text(secondsRemaining.map { formatDuration($0) } ?? "--:--")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(isExpiringSoon ? .red : .primary)
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let err = refreshError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task {
                    isRefreshing = true
                    refreshError = nil
                    do {
                        try await service.forceRefresh()
                        if let j = currentJWT { qrImage = generateQR(from: j) }
                    } catch {
                        refreshError = error.localizedDescription
                    }
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRefreshing ? "Refreshing…" : "Refresh QR")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.navy)
            .disabled(isRefreshing)

            if qrImage != nil {
                Button {
                    showShareSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share QR")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(Color.navy)
                .sheet(isPresented: $showShareSheet) {
                    if let img = qrImage {
                        QRShareSheet(items: [img])
                    }
                }
            }
        }
    }

    // MARK: - Legal disclaimer

    private var legalDisclaimer: some View {
        Text(
            "⚠ Only share your QR with treating clinicians. " +
            "The QR is valid for 15 minutes, contains a self-verifying signature, " +
            "and cannot be reused after expiry."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8)
    }

    // MARK: - QR generation (CIQRCodeGenerator, error correction H)

    private func generateQR(from jwt: String) -> UIImage? {
        guard let data = jwt.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")  // 30% error tolerance
        guard let output = filter.outputImage else { return nil }

        let pixelSize: CGFloat = 560   // 2× physical: sharp at all screen densities
        let scaleX = pixelSize / output.extent.width
        let scaleY = pixelSize / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - QRShareSheet

private struct QRShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview {
    QRGeneratorView()
}
