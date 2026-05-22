import Foundation
import Combine
import CoreTelephony
import Network

// MCC (Mobile Country Code) → ISO 3166-1 alpha-2
// Uses the SERVING network tower, not the SIM home country.
// Ukrainian patient in Lisbon: mobileCountryCode="268" → PT → "pt" ✅
// isoCountryCode would wrongly return "ua" — never use it for location.
private let mccToISO: [String: String] = [
    "202": "GR", "204": "NL", "206": "BE", "208": "FR",
    "212": "MC", "213": "AD", "214": "ES", "216": "HU",
    "218": "BA", "219": "HR", "220": "RS", "222": "IT",
    "226": "RO", "228": "CH", "230": "CZ", "231": "SK",
    "232": "AT", "234": "GB", "238": "DK", "240": "SE",
    "242": "NO", "244": "FI", "246": "LT", "247": "LV",
    "248": "EE", "250": "RU", "255": "UA", "257": "BY",
    "260": "PL", "262": "DE", "266": "GI", "268": "PT",
    "270": "LU", "272": "IE", "274": "IS", "276": "AL",
    "278": "MT", "280": "CY", "282": "GE", "283": "AM",
    "284": "BG", "286": "TR", "288": "FO", "289": "GE",
    "290": "GL", "292": "SM", "293": "SI", "294": "MK",
    "295": "LI", "297": "ME"
]

// Serving network country → display language for Emergency card.
// Falls back to English when no opus-mt model is available.
private let isoToLanguage: [String: String] = [
    "DE": "de", "AT": "de", "CH": "de", "LU": "de",
    "PT": "pt", "BR": "pt",
    "UA": "uk",
    "RU": "ru",
    "FR": "fr", "BE": "fr", "MC": "fr",
    "IT": "it",
    "ES": "es",
    "PL": "en", "CZ": "en", "SK": "en", "HU": "en",
    "RO": "en", "BG": "en", "HR": "en", "SI": "en",
    "GR": "en", "NL": "en", "SE": "en", "NO": "en",
    "DK": "en", "FI": "en", "IE": "en", "GB": "en"
]

// Timezone → ISO fallback (last resort, no network needed)
private let timezoneToISO: [String: String] = [
    "Europe/Berlin": "DE", "Europe/Vienna": "AT",
    "Europe/Zurich": "CH",
    "Europe/Lisbon": "PT",
    "Europe/Kyiv": "UA",
    "Europe/Paris": "FR",
    "Europe/Rome": "IT",
    "Europe/Madrid": "ES",
    "Europe/Warsaw": "PL",
    "Europe/Prague": "CZ",
    "Europe/Bratislava": "SK",
    "Europe/Budapest": "HU",
    "Europe/Bucharest": "RO",
    "Europe/Sofia": "BG",
    "Europe/Zagreb": "HR",
    "Europe/Ljubljana": "SI",
    "Europe/Athens": "GR",
    "Europe/Amsterdam": "NL",
    "Europe/Stockholm": "SE",
    "Europe/Oslo": "NO",
    "Europe/Copenhagen": "DK",
    "Europe/Helsinki": "FI",
    "Europe/Dublin": "IE",
    "Europe/London": "GB"
]

enum DetectionSource {
    case servingNetwork   // MCC from cell tower — most accurate
    case ipGeolocation    // IP lookup — good for WiFi-only
    case timezone         // offline fallback
    case manual           // user explicitly chose
}

struct DetectedCountry: Equatable {
    let isoCode: String
    let language: String
    let source: DetectionSource
    let detectedAt: Date

    var flag: String {
        // Convert ISO code to flag emoji
        isoCode.unicodeScalars.reduce("") {
            $0 + String(UnicodeScalar(127397 + $1.value)!)
        }
    }

    var sourceLabel: String {
        switch source {
        case .servingNetwork: return "📡 Detected via cell network"
        case .ipGeolocation:  return "🌐 Detected via IP"
        case .timezone:       return "🕐 Detected via timezone"
        case .manual:         return "✋ Set manually"
        }
    }
}

@MainActor
final class NetworkCountryDetector: ObservableObject {

    static let shared = NetworkCountryDetector()

    @Published private(set) var current: DetectedCountry = .init(
        isoCode: "GB",
        language: "en",
        source: .timezone,
        detectedAt: .now
    )

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.noborders.netmonitor")
    private var ipCacheKey = "cached_ip_country"
    private var ipCacheDate = "cached_ip_country_date"

    @Published private(set) var networkStatus: NetworkStatus = .online
    @Published private(set) var lastSyncDate: Date? = nil

    enum NetworkStatus {
        case online, offline, airplane
        var label: String {
            switch self {
            case .online:   return "🟢 Online"
            case .offline:  return "🟡 Offline · Local data"
            case .airplane: return "✈️ Airplane mode"
            }
        }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    self.networkStatus = path.usesInterfaceType(.cellular)
                        || path.usesInterfaceType(.wifi) ? .online : .online
                    self.lastSyncDate = .now
                } else {
                    self.networkStatus = path.availableInterfaces.isEmpty
                        ? .airplane : .offline
                }
            }
        }
        monitor.start(queue: queue)
    }

    // MARK: — Public API

    func detect() async {
        // Step 0: Manual override wins always
        if let manual = UserDefaults.standard.string(forKey: "emergencyLanguage"),
           let iso = UserDefaults.standard.string(forKey: "emergencyISO") {
            current = DetectedCountry(
                isoCode: iso, language: manual,
                source: .manual, detectedAt: .now)
            return
        }

        // Step 1: MCC from serving cell tower
        if let country = detectFromServingNetwork() {
            current = country
            return
        }

        // Step 2: IP geolocation (skip when offline or VPN suspected)
        if networkStatus == .online {
            if let country = await detectFromIP() {
                current = country
                return
            }
        }

        // Step 3: Timezone fallback (works fully offline)
        if let country = detectFromTimezone() {
            current = country
            return
        }

        // Step 4: English default
        current = DetectedCountry(
            isoCode: "GB", language: "en",
            source: .timezone, detectedAt: .now)
    }

    func setManual(isoCode: String, language: String) {
        UserDefaults.standard.set(language, forKey: "emergencyLanguage")
        UserDefaults.standard.set(isoCode, forKey: "emergencyISO")
        current = DetectedCountry(
            isoCode: isoCode, language: language,
            source: .manual, detectedAt: .now)
    }

    func clearManual() {
        UserDefaults.standard.removeObject(forKey: "emergencyLanguage")
        UserDefaults.standard.removeObject(forKey: "emergencyISO")
        Task { await detect() }
    }

    // MARK: — Detection strategies

    private func detectFromServingNetwork() -> DetectedCountry? {
        let info = CTTelephonyNetworkInfo()
        guard let providers = info.serviceSubscriberCellularProviders else {
            return nil
        }
        // Check all SIMs — prefer one that is currently serving (roaming aware)
        for (_, carrier) in providers {
            guard let mcc = carrier.mobileCountryCode,
                  !mcc.isEmpty,
                  let iso = mccToISO[mcc] else { continue }
            let lang = isoToLanguage[iso] ?? "en"
            return DetectedCountry(
                isoCode: iso, language: lang,
                source: .servingNetwork, detectedAt: .now)
        }
        return nil
    }

    private func detectFromIP() async -> DetectedCountry? {
        // Check 1-hour cache first
        if let cached = UserDefaults.standard.string(forKey: ipCacheKey),
           let cacheDate = UserDefaults.standard.object(
               forKey: ipCacheDate) as? Date,
           Date().timeIntervalSince(cacheDate) < 3600,
           let iso = mccToISO.values.first(where: { _ in true }),
           let _ = isoToLanguage[cached] {
            let lang = isoToLanguage[cached] ?? "en"
            return DetectedCountry(
                isoCode: cached, language: lang,
                source: .ipGeolocation, detectedAt: cacheDate)
        }

        guard let url = URL(string: "https://ipapi.co/json/") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any],
               let iso = json["country_code"] as? String {
                let lang = isoToLanguage[iso] ?? "en"
                // Cache result
                UserDefaults.standard.set(iso, forKey: ipCacheKey)
                UserDefaults.standard.set(Date(), forKey: ipCacheDate)
                return DetectedCountry(
                    isoCode: iso, language: lang,
                    source: .ipGeolocation, detectedAt: .now)
            }
        } catch { }
        return nil
    }

    private func detectFromTimezone() -> DetectedCountry? {
        let tz = TimeZone.current.identifier
        guard let iso = timezoneToISO[tz] else { return nil }
        let lang = isoToLanguage[iso] ?? "en"
        return DetectedCountry(
            isoCode: iso, language: lang,
            source: .timezone, detectedAt: .now)
    }
}
