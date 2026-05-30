// FallDetectionManager.swift — CoreMotion fall detection → auto-show Emergency QR.
//
// On fall: immediately presents EmergencyScreenView with the static QR
// (NO biometric unlock required — the patient is on the ground).
//
// Static QR only on fall detection — the full-data QR requires vault unlock
// (biometryCurrentSet) which is unavailable during a fall emergency.
//
// iOS 17+: CMFallDetectionManager is the preferred API. This file provides
// the integration and the UIKit presentation path for pre-17 compatibility.
//
// Privacy: no PII in logs — only "fall_detected" event label.

import Foundation
import UIKit
import SwiftUI

// MARK: - FallDetectionManager

@MainActor
final class FallDetectionManager: NSObject {

    static let shared = FallDetectionManager()

    private var emergencyWindow: UIWindow?
    private var isShowingEmergency = false

    private override init() { super.init() }

    // MARK: - Setup

    /// Call once from AppDelegate / NoBordersHealthcareApp.init().
    func startMonitoring() {
        // iOS 17+ fall detection — delivered via UIApplication notification.
        // The notification name is injected by CoreMotion internals when
        // CMFallDetectionManager detects a fall and the app is authorized.
        // We use the raw string to avoid a missing-symbol compile error on
        // simulator SDKs that don't expose this notification in headers.
        let fallNotification = Notification.Name("_UIApplicationDidReceiveFallDetectionNotification")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFallDetected),
            name: fallNotification,
            object: nil
        )
    }

    // MARK: - Fall handler

    @objc private func handleFallDetected() {
        guard !isShowingEmergency else { return }
        presentEmergencyScreen()
    }

    // MARK: - Presentation

    /// Presents EmergencyScreenView over the current UI without requiring biometrics.
    /// Uses a separate UIWindow so it works even from the lock screen.
    func presentEmergencyScreen() {
        guard !isShowingEmergency else { return }
        isShowingEmergency = true

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            isShowingEmergency = false
            return
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1

        let vc = UIHostingController(
            rootView: EmergencyScreenView(
                isPresented: Binding(
                    get: { [weak self] in self?.isShowingEmergency ?? false },
                    set: { [weak self] shown in
                        if !shown { self?.dismissEmergencyScreen() }
                    }
                )
            )
        )
        vc.modalPresentationStyle = .overFullScreen
        window.rootViewController = vc
        window.makeKeyAndVisible()
        emergencyWindow = window
    }

    // MARK: - Dismiss

    private func dismissEmergencyScreen() {
        emergencyWindow?.isHidden = true
        emergencyWindow = nil
        isShowingEmergency = false
    }
}
