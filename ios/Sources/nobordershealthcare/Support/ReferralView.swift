// ReferralView.swift — "Invite & Earn" panel in the Profile tab.
//
// Security notes:
//   - Referral codes are opaque strings; no user PII is displayed or shared
//   - All API calls use the existing authenticated session token
//   - Referral links use the public short domain only (no internal IDs)

import SwiftUI

// MARK: - View Model

@MainActor
final class ReferralViewModel: ObservableObject {

    enum UserKind { case civilian, partner, affiliate }

    @Published var code: String = ""
    @Published var shortLink: String = ""
    @Published var stats: ReferralStats = .empty
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var userKind: UserKind = .civilian

    private let apiBase: String = AppConfig.apiBaseURL.absoluteString

    // Load referral code and stats for the current user.
    func load(referrerHash: String, kind: UserKind) async {
        userKind = kind
        isLoading = true
        defer { isLoading = false }
        do {
            let codeResp = try await fetchCode(referrerHash: referrerHash)
            code = codeResp.code
            shortLink = codeResp.shortLink
            let statsResp = try await fetchStats(referrerHash: referrerHash)
            stats = statsResp
        } catch {
            errorMessage = "Could not load referral data."
        }
    }

    private func fetchCode(referrerHash: String) async throws -> CodeResponse {
        // POST /referral/code/create — returns existing or creates new code
        var req = URLRequest(url: URL(string: "\(apiBase)/referral/code/create")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(referrerHash, forHTTPHeaderField: "X-Referrer-Hash")
        let body: [String: String] = ["referral_type": referralType(for: userKind)]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(CodeResponse.self, from: data)
    }

    private func fetchStats(referrerHash: String) async throws -> ReferralStats {
        let url = URL(string: "\(apiBase)/referral/stats/\(referrerHash)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(ReferralStats.self, from: data)
    }

    private func referralType(for kind: UserKind) -> String {
        switch kind {
        case .civilian:  return "individual"
        case .partner:   return "partner"
        case .affiliate: return "affiliate"
        }
    }

    struct CodeResponse: Decodable {
        let code: String
        let shortLink: String
        enum CodingKeys: String, CodingKey {
            case code
            case shortLink = "short_link"
        }
    }

    struct ReferralStats: Decodable {
        let totalConversions: Int
        let pendingCommission: Double
        let paidCommission: Double
        let activeReferred: Int
        let creditsEarned: Int

        static let empty = ReferralStats(
            totalConversions: 0, pendingCommission: 0,
            paidCommission: 0, activeReferred: 0, creditsEarned: 0
        )
        enum CodingKeys: String, CodingKey {
            case totalConversions  = "total_conversions"
            case pendingCommission = "pending_commission"
            case paidCommission    = "paid_commission"
            case activeReferred    = "active_referred"
            case creditsEarned     = "credits_earned"
        }
    }
}

// MARK: - Root View

struct ReferralView: View {

    @StateObject private var vm = ReferralViewModel()

    // Injected by the Profile tab — hash provided by the session layer (never raw ID)
    let referrerHash: String
    let userKind: ReferralViewModel.UserKind

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch userKind {
                case .civilian:
                    CivilianReferralPanel(vm: vm)
                case .partner, .affiliate:
                    PartnerReferralPanel(vm: vm)
                }
            }
        }
        .navigationTitle(userKind == .civilian ? "Invite & Earn" : "Partner Earnings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await vm.load(referrerHash: referrerHash, kind: userKind)
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

// MARK: - Civilian Panel ("Invite a friend")

private struct CivilianReferralPanel: View {
    @ObservedObject var vm: ReferralViewModel
    @State private var showShareSheet = false
    @State private var showQR = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero
                VStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Invite a friend")
                        .font(.title2.bold())
                    Text("You both get **1 month premium free** when your friend signs up.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)

                // Code card
                VStack(spacing: 12) {
                    Text("Your code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(vm.code.isEmpty ? "Loading…" : vm.code)
                        .font(.system(.title3, design: .monospaced).bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 12) {
                        ShareButton(title: "Copy", icon: "doc.on.doc") {
                            UIPasteboard.general.string = vm.code
                        }
                        ShareButton(title: "Share link", icon: "link") {
                            showShareSheet = true
                        }
                        ShareButton(title: "QR code", icon: "qrcode") {
                            showQR = true
                        }
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 8)

                // Direct share buttons
                HStack(spacing: 16) {
                    MessengerButton(
                        label: "WhatsApp",
                        color: Color(red: 0.07, green: 0.74, blue: 0.38),
                        icon: "message.fill",
                        action: { openMessenger(.whatsApp, link: vm.shortLink) }
                    )
                    MessengerButton(
                        label: "Telegram",
                        color: Color(red: 0.23, green: 0.57, blue: 0.84),
                        icon: "paperplane.fill",
                        action: { openMessenger(.telegram, link: vm.shortLink) }
                    )
                }

                // Stats
                HStack(spacing: 0) {
                    StatCell(label: "Friends referred", value: "\(vm.stats.totalConversions)")
                    Divider().frame(height: 40)
                    StatCell(label: "Free months earned", value: "\(vm.stats.totalConversions)")
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 8)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText(code: vm.code, link: vm.shortLink)])
        }
        .sheet(isPresented: $showQR) {
            QRCodeSheet(link: vm.shortLink)
        }
    }
}

// MARK: - Partner / Affiliate Panel

private struct PartnerReferralPanel: View {
    @ObservedObject var vm: ReferralViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Partner Earnings")
                        .font(.title2.bold())
                }
                .padding(.top)

                // Code card
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your referral code", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(vm.code.isEmpty ? "Loading…" : vm.code)
                        .font(.system(.body, design: .monospaced).bold())
                    Button {
                        UIPasteboard.general.string = vm.shortLink
                    } label: {
                        Label("Copy link", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 8)

                // Earnings summary
                VStack(spacing: 0) {
                    EarningsRow(
                        label: "This month (pending)",
                        value: String(format: "€%.2f", vm.stats.pendingCommission),
                        color: .orange
                    )
                    Divider()
                    EarningsRow(
                        label: "Total paid out",
                        value: String(format: "€%.2f", vm.stats.paidCommission),
                        color: .green
                    )
                    Divider()
                    EarningsRow(
                        label: "Active subscriptions",
                        value: "\(vm.stats.activeReferred)",
                        color: .primary
                    )
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 8)

                // Stripe dashboard link
                if let url = URL(string: "https://dashboard.stripe.com") {
                    Link(destination: url) {
                        Label("Open Stripe Dashboard", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Reusable sub-views

private struct ShareButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct MessengerButton: View {
    let label: String
    let color: Color
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct EarningsRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .bold()
                .foregroundStyle(color)
        }
        .padding()
    }
}

private struct QRCodeSheet: View {
    let link: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = generateQR(from: link) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding()
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Text(link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - UIKit bridges

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Helpers

private func shareText(code: String, link: String) -> String {
    """
    I use #nobordershealthcare for my emergency health identity across the EU.
    Get 1 free month: \(link)
    (Code: \(code))
    """
}

private enum Messenger { case whatsApp, telegram }

private func openMessenger(_ messenger: Messenger, link: String) {
    let text = shareText(code: "", link: link)
    let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let urlStr: String
    switch messenger {
    case .whatsApp: urlStr = "whatsapp://send?text=\(encoded)"
    case .telegram: urlStr  = "tg://msg?text=\(encoded)"
    }
    if let url = URL(string: urlStr), UIApplication.shared.canOpenURL(url) {
        UIApplication.shared.open(url)
    }
}

private func generateQR(from string: String) -> UIImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }
    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    return UIImage(ciImage: scaled)
}
