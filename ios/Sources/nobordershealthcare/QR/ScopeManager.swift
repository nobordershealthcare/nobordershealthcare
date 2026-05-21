// Patient-configurable IPS field subset for the emergency QR token.
// Scope is persisted in Keychain (not UserDefaults — scope selection is security-sensitive).
// Revocation: issuing a new token with a new jti invalidates the previous one server-side.

import Foundation
import Security

struct EmergencyScope: Sendable, Codable, Equatable {
    var includeAllergies:   Bool = true
    var includeMedications: Bool = true
    var includeConditions:  Bool = true
    var includeBloodGroup:  Bool = false
    var includeLabResults:  Bool = false

    var asIPSFilter: IPSScopeFilter {
        var filter = IPSScopeFilter()
        if includeAllergies   { filter.insert(.allergies) }
        if includeMedications { filter.insert(.medications) }
        if includeConditions  { filter.insert(.problems) }
        if includeLabResults  { filter.insert(.results) }
        return filter
    }

    static let defaultEmergency = EmergencyScope()
}

actor ScopeManager {

    static let shared = ScopeManager()

    private let scopeAccount = "com.noborders.scope.emergency"
    private var cached: EmergencyScope?

    func currentScope() throws -> EmergencyScope {
        if let c = cached { return c }
        let scope = (try? loadScope()) ?? .defaultEmergency
        cached = scope
        return scope
    }

    func updateScope(_ scope: EmergencyScope) throws {
        try saveScope(scope)
        cached = scope
        // Caller must re-issue the EmergencyCard token after scope change.
    }

    // MARK: - Persistence

    private func loadScope() throws -> EmergencyScope {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: scopeAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ScopeError.keychainFailed(status)
        }
        return try JSONDecoder().decode(EmergencyScope.self, from: data)
    }

    private func saveScope(_ scope: EmergencyScope) throws {
        let data = try JSONEncoder().encode(scope)
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     scopeAccount,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ScopeError.keychainFailed(status) }
    }

    enum ScopeError: Error {
        case keychainFailed(OSStatus)
    }
}
