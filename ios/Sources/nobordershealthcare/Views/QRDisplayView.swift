// QRDisplayView.swift — Reusable QR display component.
//
// Renders a QR image inside a circular border whose colour signals state:
//   gray  → staticLink  (physician URL only, never expires)
//   red   → fullData + offline  (self-contained JWT, no network)
//   blue  → fullData + online   (JWT served/verified online)
//
// The NBHC logo mark is composited in the QR centre (20% of frame width).
// Error correction level H (30%) ensures the logo never breaks decode.
//
// Staleness warning: shows ⚠ badge when jwt.v < blockchain version.
// Screenshot protection: caller is responsible for .blur() overlay when
//   isSceneCaptured == true (see EmergencyScreenView).

import SwiftUI

// MARK: - QRDisplayView

struct QRDisplayView: View {

    let mode:     QRMode
    let qrImage:  UIImage?
    let isStale:  Bool
    let isOnline: Bool

    /// Outer frame size — caller controls layout; this view fills the frame.
    /// Defaults to 300 pt which is readable at arm's length.
    var frameSize: CGFloat = 300

    // MARK: - Border colour

    private var borderColor: Color {
        switch mode {
        case .staticLink: return .gray
        case .fullData:   return isOnline ? .blue : .red
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── QR image or placeholder ──────────────────────────────────
            if let img = qrImage {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                qrPlaceholder
            }

            // ── Centred logo mark (20% of frame, white background) ──────
            logoMark
        }
        .frame(width: frameSize, height: frameSize)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            Circle()
                .stroke(borderColor, lineWidth: 4)
                .frame(width: frameSize + 12, height: frameSize + 12)
        )
        .overlay(alignment: .bottom) {
            if isStale { stalenessWarning }
        }
    }

    // MARK: - Sub-views

    private var qrPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode")
                .font(.system(size: frameSize * 0.25))
                .foregroundStyle(.secondary)
            Text("Generating…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logoMark: some View {
        let size = frameSize * 0.18
        return Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(
                // Use system symbol until the asset NBHC logo is available
                Image(systemName: "cross.circle.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(Color.navy)
            )
            .shadow(color: .black.opacity(0.12), radius: 4)
    }

    private var stalenessWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("QR may be outdated — tap Regenerate")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .offset(y: 20)
    }
}

// MARK: - Preview

#Preview("Static QR") {
    QRDisplayView(
        mode: .staticLink,
        qrImage: QRGenerator.generateStaticQR(pid: "abc1234567890def"),
        isStale: false,
        isOnline: false
    )
    .padding(40)
}

#Preview("Full data QR — stale, offline") {
    QRDisplayView(
        mode: .fullData,
        qrImage: nil,
        isStale: true,
        isOnline: false
    )
    .padding(40)
}
