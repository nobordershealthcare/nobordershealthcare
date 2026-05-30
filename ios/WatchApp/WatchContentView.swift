// WatchContentView.swift — Apple Watch emergency QR display.
// TARGET: nobordershealthcareWatch (add via Xcode: File → New → Target → watchOS App)
//         Bundle ID: com.valeriy.nobordershealthcare.watchkitapp
//
// Shows the full data QR if available, static QR as fallback.
// Data synced from iPhone via WatchConnectivity.
// Circular border: gray = static, red = full data offline, blue = full data online.

import SwiftUI
import WatchKit

struct WatchContentView: View {

    @StateObject private var vm = WatchEmergencyViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {

                Text("EMERGENCY")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.red)
                    .tracking(1)

                qrSection

                if vm.isStale {
                    Label("Outdated", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if vm.isSyncing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Syncing…")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
        .onAppear { vm.loadFromPhone() }
    }

    @ViewBuilder
    private var qrSection: some View {
        if let img = vm.qrImage {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(vm.borderColor, lineWidth: 2)
                )
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.darkGray).opacity(0.3))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "qrcode")
                        .font(.title)
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - ViewModel

@MainActor
final class WatchEmergencyViewModel: ObservableObject {

    @Published var qrImage:     UIImage?
    @Published var isStale:     Bool = false
    @Published var hasFullData: Bool = false
    @Published var isSyncing:   Bool = false

    var borderColor: Color {
        hasFullData ? .red : .gray
    }

    func loadFromPhone() {
        guard !isSyncing else { return }
        isSyncing = true
        WatchConnectivityManager.shared.requestQRData { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSyncing = false
                if let jwt = data["jwt"] as? String {
                    self.qrImage     = QRGenerator.generateFullDataQR(
                        jwt: jwt, size: CGSize(width: 160, height: 160))
                    self.hasFullData  = true
                    self.isStale     = data["stale"] as? Bool ?? false
                } else if let pid = data["pid"] as? String {
                    self.qrImage     = QRGenerator.generateStaticQR(
                        pid: pid, size: CGSize(width: 160, height: 160))
                    self.hasFullData  = false
                    self.isStale     = false
                }
            }
        }
    }
}
