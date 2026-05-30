// WatchQRGenerator.swift — Watch-side QR display helper.
//
// CoreImage / CIFilter are NOT available on watchOS.
// The iPhone renders the QR PNG and sends it over WatchConnectivity.
// This file decodes the received PNG data into a UIImage for display.

import Foundation
import UIKit

enum WatchQRGenerator {

    /// Decode PNG image data received from the iPhone via WatchConnectivity.
    static func imageFromData(_ data: Data) -> UIImage? {
        UIImage(data: data)
    }
}
