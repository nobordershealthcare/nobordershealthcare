// Generates a CoreImage QR code from the ScopedJWT raw token string.
// Error correction level H (30%) — chosen for readability at small sizes on lock screen.
// Returns a UIImage ready for display; caller sizes it appropriately.

import Foundation
import CoreImage
import UIKit

enum QRGenerator {

    enum QRError: Error {
        case filterFailed
        case outputImageMissing
        case renderFailed
    }

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

    // Convenience: generates QR from the current live token.
    // Returns nil if the token is expired (caller should prompt for refresh).
    static func currentQR(size: CGSize = CGSize(width: 300, height: 300)) async throws -> UIImage? {
        let token = try await ScopedTokenActor.shared.loadCurrentToken()
        if case .expired = try await ScopedTokenActor.shared.tokenState() { return nil }
        return try image(for: token, size: size)
    }
}
