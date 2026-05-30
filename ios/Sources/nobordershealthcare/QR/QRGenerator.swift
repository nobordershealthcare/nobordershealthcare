// QRGenerator.swift — CoreImage QR generation for all three QR modes.
//
// MODE 1: staticLink  — physician URL only (pid-based, never expires)
// MODE 2: fullData    — JWT payload (self-contained, offline-capable)
//
// Error correction level H (30%) — chosen for resilience at small lock-screen sizes
// and to allow the centered logo mark to obscure ~20% without decode failure.
//
// URL construction: AppConfig.physicianViewURL — NEVER a string literal.
// Hashing: SHA3_256 (project standard); SHA-256 is NOT used here.

import Foundation
import CoreImage
import UIKit

// MARK: - QRMode

enum QRMode {
    case staticLink   // gray border — physician URL, no expiry
    case fullData     // red (offline) or blue (online) border — JWT payload
}

// MARK: - QRGenerator

enum QRGenerator {

    enum QRError: Error {
        case filterFailed
        case outputImageMissing
        case renderFailed
    }

    // ── Default render size (2× logical — sharp on all screen densities) ────
    static let defaultSize = CGSize(width: 560, height: 560)

    // MARK: - Static QR (Mode 1)
    //
    // Contains only: physician.noborders.healthcare/p/{pid}
    // Safe to display without biometric unlock (no medical data in payload).
    // pid = first 16 hex chars of the patient's stored userIdHash.

    /// Derives the 16-char PID from the full userIdHash stored by DIDWallet/IdentityVaultManager.
    /// Input must be a 64-char lowercase SHA3-256 hex string (validated before calling).
    static func makePID(from userIdHash: String) -> String {
        String(userIdHash.prefix(16))
    }

    /// Generates a static QR from a pid.
    /// URL built via AppConfig — never hardcoded.
    static func generateStaticQR(
        pid: String,
        size: CGSize = defaultSize
    ) -> UIImage? {
        let url = AppConfig.physicianViewURL
            .appendingPathComponent("p")
            .appendingPathComponent(pid)
            .absoluteString
        return renderQR(from: url, size: size)
    }

    // MARK: - Full data QR (Mode 2)
    //
    // Contains the complete signed JWT payload.
    // Works fully offline — no network call required to verify.
    // Physician scans → their device verifies Ed25519 signature locally.

    /// Generates a full-data QR from a raw JWT string.
    static func generateFullDataQR(
        jwt: String,
        size: CGSize = defaultSize
    ) -> UIImage? {
        renderQR(from: jwt, size: size)
    }

    // MARK: - Legacy: ScopedJWT (kept for QRGeneratorView backward compat)

    static func image(for token: ScopedJWT, size: CGSize = CGSize(width: 300, height: 300)) throws -> UIImage {
        guard let data = token.rawToken.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { throw QRError.filterFailed }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { throw QRError.outputImageMissing }

        let scaleX = size.width  / output.extent.width
        let scaleY = size.height / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRError.renderFailed
        }
        return UIImage(cgImage: cgImage)
    }

    static func currentQR(size: CGSize = CGSize(width: 300, height: 300)) async throws -> UIImage? {
        let token = try await ScopedTokenActor.shared.loadCurrentToken()
        if case .expired = try await ScopedTokenActor.shared.tokenState() { return nil }
        return try image(for: token, size: size)
    }

    // MARK: - Private rendering

    private static func renderQR(from string: String, size: CGSize) -> UIImage? {
        guard let data   = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        let scaleX = size.width  / output.extent.width
        let scaleY = size.height / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
