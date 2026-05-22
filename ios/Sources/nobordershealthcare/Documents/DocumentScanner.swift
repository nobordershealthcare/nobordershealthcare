// DocumentScanner.swift — wraps VNDocumentCameraViewController for SwiftUI.
//
// Uses the iOS built-in document scanner: perspective correction, glare removal,
// and multi-page capture are handled natively by VisionKit.
// No third-party SDK, no network, no cloud upload.
//
// Output: [UIImage] — one UIImage per scanned page, in scan order.
// Typical resolution: 2268 × 3024 px on iPhone (roughly 300 DPI on A4).

import SwiftUI
import VisionKit
import UIKit

// MARK: - DocumentScannerView

/// A SwiftUI-presentable wrapper around VNDocumentCameraViewController.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showScanner) {
///     DocumentScannerView { pages in
///         // pages: [UIImage], one per scanned side
///     } onCancel: {
///         showScanner = false
///     }
/// }
/// ```
struct DocumentScannerView: UIViewControllerRepresentable {

    /// Called on a successful scan with one `UIImage` per page, in order.
    var onScan: ([UIImage]) -> Void

    /// Called when the user taps Cancel or if the device camera fails.
    var onCancel: () -> Void

    // MARK: UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(
        _ uiViewController: VNDocumentCameraViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {

        private let onScan: ([UIImage]) -> Void
        private let onCancel: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan   = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images = [UIImage]()
            images.reserveCapacity(scan.pageCount)
            for i in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: i))
            }
            controller.dismiss(animated: true)
            onScan(images)
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            controller.dismiss(animated: true)
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            // Surface the error to the caller by treating failure as a cancel.
            // The store layer logs and handles missing pages gracefully.
            controller.dismiss(animated: true)
            onCancel()
        }
    }
}

// MARK: - Availability

extension DocumentScannerView {
    /// True if VNDocumentCameraViewController is supported on this device.
    /// Always true on iPhone; may be false on some iPad configurations without
    /// a rear camera. Check before presenting the scan button.
    static var isAvailable: Bool {
        VNDocumentCameraViewController.isSupported
    }
}
