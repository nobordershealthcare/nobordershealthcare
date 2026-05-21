// xLMEngine.swift — Translation engine for noborders health wallet
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  ARCHITECTURE INVARIANT — READ BEFORE TOUCHING THIS FILE               │
// │                                                                         │
// │  Medical content  →  translateMedical()  →  OpusMTEngine (CoreML)      │
// │                        strictly on-device, zero network calls           │
// │                                                                         │
// │  UI strings only  →  translateUI()  →  Apple Translation framework      │
// │                        cloud-backed, NEVER receives clinical data       │
// │                                                                         │
// │  These two paths MUST NEVER be swapped. Patient data may never leave   │
// │  the device via a translation API call.                                 │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Supported medical translation pairs (pilot — Hospital da Luz):
//   EN → UK  (Ukrainian)    ODR tag: "opus-mt-en-uk"  ~85 MB
//   EN → RU  (Russian)      ODR tag: "opus-mt-en-ru"  ~85 MB
//   EN → DE  (German)       ODR tag: "opus-mt-en-de"  ~85 MB
//   EN → PT  (Portuguese)   ODR tag: "opus-mt-en-pt"  ~85 MB
//
// Models are Helsinki-NLP opus-mt, converted to CoreML (.mlpackage).
// Bundled as On-Demand Resources so the base app download stays small.
// Vocabulary files (.spm) are bundled alongside each model in the ODR tag.

import Foundation
import CoreML
@preconcurrency import Translation  // TranslationSession lacks Sendable in current SDK
// SentencePieceC is the C module exposed by sentencepiece-ios.xcframework.
// Build the framework first: ./scripts/build-sentencepiece-ios.sh
// Then add it to Package.swift as a .binaryTarget and list it in the target
// dependencies so this import resolves.
import SentencePieceC

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - SentencePiece tokenizer protocol
// ═══════════════════════════════════════════════════════════════════════════
//
// Backed by the C wrapper (sentencepiece_c_wrapper.h / .cpp) built into
// sentencepiece-ios.xcframework.  Swift cannot call C++ APIs directly so
// the XCFramework exposes only C linkage symbols via the SentencePieceC
// module map.
//
// CoreML model interface (from scripts/convert-opus-mt-to-coreml.py):
//   Encoder:
//     Inputs:  "input_ids"      — MLMultiArray Int32  [1 × MAX_SRC_LEN]
//              "attention_mask" — MLMultiArray Int32  [1 × MAX_SRC_LEN]
//     Output:  "encoder_hidden_states" — Float32 [1 × MAX_SRC_LEN × hidden]
//   Decoder (single step, called in a loop):
//     Inputs:  "decoder_input_ids" — Int32  [1 × 1]
//              "encoder_hidden"    — Float32 [1 × MAX_SRC_LEN × hidden]
//              "encoder_mask"      — Int32  [1 × MAX_SRC_LEN]
//     Output:  "logits"           — Float32 [1 × 1 × vocab_size]

protocol SentencePieceTokenizing {
    /// BOS token ID used as the first decoder input token.
    var bosID: Int32 { get }
    /// EOS token ID — stop decoding when this is predicted.
    var eosID: Int32 { get }

    /// Encode `text` to a sequence of vocabulary token IDs.
    func encode(_ text: String) -> [Int32]

    /// Decode a sequence of token IDs back to a UTF-8 string.
    func decode(_ tokens: [Int32]) -> String
}

// ── Concrete implementation — SentencePieceC XCFramework ─────────────────

final class SentencePieceTokenizer: SentencePieceTokenizing {

    // Maximum token buffer sizes (must match MAX_SRC_LEN in the Python script).
    private static let encodeCapacity: Int32 = 64
    private static let decodeBufferSize: Int32 = 1024

    private let handle: SPMHandle   // opaque C pointer, non-null after init

    let bosID: Int32
    let eosID: Int32

    init(vocabURL: URL) throws {
        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw OpusMTError.vocabularyNotFound(vocabURL.lastPathComponent)
        }

        // spm_load returns NULL and logs to stderr on failure.
        guard let h = spm_load(vocabURL.path) else {
            throw OpusMTError.vocabularyNotFound(vocabURL.lastPathComponent)
        }
        handle = h
        bosID  = spm_bos_id(handle)
        eosID  = spm_eos_id(handle)
    }

    deinit {
        spm_free(handle)
    }

    func encode(_ text: String) -> [Int32] {
        var ids   = [Int32](repeating: 0, count: Int(Self.encodeCapacity))
        var count: Int32 = 0
        let rc = spm_encode(handle, text, &ids, Self.encodeCapacity, &count)
        guard rc == 0, count > 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func decode(_ tokens: [Int32]) -> String {
        var buf = [CChar](repeating: 0, count: Int(Self.decodeBufferSize))
        let rc  = spm_decode(handle, tokens, Int32(tokens.count), &buf, Self.decodeBufferSize)
        guard rc == 0 else { return "" }
        return String(cString: buf)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - OpusMT errors
// ═══════════════════════════════════════════════════════════════════════════

enum OpusMTError: LocalizedError {
    case unsupportedLanguage(String)
    case modelNotFound(String)
    case vocabularyNotFound(String)
    case odrDownloadFailed(String, Error)
    case inferenceFailed(String)
    case inputTooLong(Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let lang):
            return "opus-mt: language '\(lang)' not in pilot set (uk, ru, de, pt)"
        case .modelNotFound(let name):
            return "opus-mt: model '\(name)' not found in bundle after ODR download"
        case .vocabularyNotFound(let name):
            return "opus-mt: vocabulary '\(name)' not found in bundle"
        case .odrDownloadFailed(let tag, let err):
            return "opus-mt: ODR download failed for tag '\(tag)': \(err.localizedDescription)"
        case .inferenceFailed(let reason):
            return "opus-mt: inference failed — \(reason)"
        case .inputTooLong(let count, let max):
            return "opus-mt: input \(count) chars exceeds limit of \(max)"
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - OpusMTEngine  (MEDICAL CONTENT — strictly on-device CoreML)
// ═══════════════════════════════════════════════════════════════════════════
//
// All medical terminology label translation flows through this actor.
// It is an actor (not @MainActor) so inference runs off the main queue
// without blocking the UI thread.
//
// INVARIANT: This engine makes ZERO network calls. If you ever add a network
// call inside this actor you have violated the architecture. Do not do it.

actor OpusMTEngine {

    static let shared = OpusMTEngine()

    // Language codes supported in the pilot.
    // Each corresponds to one ODR tag: "opus-mt-en-{lang}"
    static let pilotLanguages: Set<String> = ["uk", "ru", "de", "pt"]

    // Maximum input length in characters. TerminologyMapper labels are always
    // well under this — the guard exists to catch accidental misuse (e.g. a
    // clinical note being passed instead of a label).
    static let maxInputCharacters = 200

    // CoreML greedy-decode output cap. Terminology labels rarely exceed 50 tokens.
    private static let maxOutputTokens = 128

    // Special token IDs come from the loaded SentencePiece tokenizer via
    // spm_bos_id() / spm_eos_id().  These fallback constants are used only if
    // the vocabulary file has not been loaded yet (should never happen in
    // normal operation — the tokenizer is loaded before any inference call).
    private static let bosTokenIDFallback: Int32 = 0   // <pad> / BOS
    private static let eosTokenIDFallback: Int32 = 0   // </s>

    // Cache keyed by BCP-47 primary language subtag.
    // Stores the loaded encoder + decoder MLModels and the ODR request.
    // The ODR request MUST be retained — releasing it signals to the OS that
    // the resource bundle can be purged.
    private struct CachedModel {
        let encoder: MLModel    // opus-mt-en-{lang}-encoder.mlpackage
        let decoder: MLModel    // opus-mt-en-{lang}-decoder.mlpackage (single step)
        let tokenizer: any SentencePieceTokenizing
        // MAX_SRC_LEN as fixed in the CoreML static input shape (from manifest.json).
        // Must match the value used during conversion (default: 64).
        let encoderSeqLen: Int
        let odrRequest: NSBundleResourceRequest // retained to prevent purge
    }
    private var cache: [String: CachedModel] = [:]

    // ── Public translation entry point ────────────────────────────────────

    /// Translate a medical terminology display label on-device via CoreML.
    ///
    /// - Parameters:
    ///   - text: Canonical English label from TerminologyMapper (≤200 chars).
    ///   - lang: BCP-47 primary subtag of the target language ("uk", "de", etc.).
    /// - Returns: Translated display label, or `text` if the language is not in
    ///            the pilot set (English fallback — never throws to the UI).
    ///
    /// CONTRACT: `text` MUST be a TerminologyMapper output label.
    ///           It MUST NOT be a raw clinical code, patient name, DOB, or any
    ///           content sourced directly from a FHIR resource field.
    func translate(_ text: String, lang: String) async throws -> String {
        let primary = primaryLanguageTag(lang)

        // Graceful English fallback for unsupported languages.
        guard Self.pilotLanguages.contains(primary) else {
            return text
        }

        // Input length guard — catch accidental misuse before inference.
        guard text.count <= Self.maxInputCharacters else {
            throw OpusMTError.inputTooLong(text.count, max: Self.maxInputCharacters)
        }

        let cached = try await loadModel(lang: primary)
        return try runInference(text: text, bundle: cached)
    }

    // ── Model loading (ODR + CoreML) ──────────────────────────────────────

    private func loadModel(lang: String) async throws -> CachedModel {
        if let hit = cache[lang] { return hit }

        let tag = "opus-mt-en-\(lang)"
        let request = NSBundleResourceRequest(tags: [tag])
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent

        // beginAccessingResources() downloads the ODR bundle if not already cached.
        // This is the ONLY network call in this engine — it fetches the model file
        // itself from the App Store CDN, not patient data.
        do {
            try await request.beginAccessingResources()
        } catch {
            throw OpusMTError.odrDownloadFailed(tag, error)
        }

        let base = "opus-mt-en-\(lang)"

        // Locate the split encoder + decoder .mlpackages.
        guard let encoderURL = Bundle.main.url(forResource: "\(base)-encoder",
                                                withExtension: "mlpackage") else {
            request.endAccessingResources()
            throw OpusMTError.modelNotFound("\(base)-encoder.mlpackage")
        }
        guard let decoderURL = Bundle.main.url(forResource: "\(base)-decoder",
                                                withExtension: "mlpackage") else {
            request.endAccessingResources()
            throw OpusMTError.modelNotFound("\(base)-decoder.mlpackage")
        }

        // Locate the SentencePiece vocabulary file bundled with the ODR pack.
        guard let vocabURL = Bundle.main.url(forResource: base, withExtension: "spm") else {
            request.endAccessingResources()
            throw OpusMTError.vocabularyNotFound("\(base).spm")
        }

        // Load both CoreML models.
        // .cpuAndNeuralEngine — prefer ANE (Neural Engine), fall back to CPU.
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let encoder = try MLModel(contentsOf: encoderURL, configuration: config)
        let decoder = try MLModel(contentsOf: decoderURL, configuration: config)

        let tokenizer = try SentencePieceTokenizer(vocabURL: vocabURL)

        // Read the encoder's static sequence length from the model description.
        // Falls back to 64 (the MAX_SRC_LEN used during conversion) if the
        // shape metadata is unavailable.
        let encoderSeqLen: Int = {
            let desc = encoder.modelDescription.inputDescriptionsByName
            if let inputDesc = desc["input_ids"],
               let constraint = inputDesc.multiArrayConstraint,
               constraint.shape.count >= 2 {
                return constraint.shape[1].intValue
            }
            return 64
        }()

        let cached = CachedModel(
            encoder: encoder,
            decoder: decoder,
            tokenizer: tokenizer,
            encoderSeqLen: encoderSeqLen,
            odrRequest: request
        )
        cache[lang] = cached
        return cached
    }

    // ── CoreML inference (greedy decode, split encoder+decoder) ──────────
    //
    // The conversion script exports MarianMT as two separate CoreML models:
    //   1. Encoder (one forward pass) — produces encoder_hidden_states
    //   2. Decoder (single step) — takes (decoder_input_ids, encoder_hidden,
    //      encoder_mask) and returns logits [1 × 1 × vocab_size]
    //
    // The Swift inference loop calls the decoder step-by-step (greedy argmax)
    // until EOS is predicted or maxOutputTokens is reached.
    //
    // CoreML feature names:
    //   Encoder inputs:  "input_ids", "attention_mask"
    //   Encoder output:  "encoder_hidden_states"
    //   Decoder inputs:  "decoder_input_ids", "encoder_hidden", "encoder_mask"
    //   Decoder output:  "logits"

    private func runInference(text: String, bundle: CachedModel) throws -> String {
        var inputIDs = bundle.tokenizer.encode(text)
        guard !inputIDs.isEmpty else { return text }

        let seqLen = bundle.encoderSeqLen  // static shape from the CoreML model

        // Pad or truncate to the encoder's fixed sequence length.
        if inputIDs.count > seqLen {
            inputIDs = Array(inputIDs.prefix(seqLen))
        }
        let padID: Int32 = bundle.tokenizer.bosID  // <pad> == BOS for MarianMT

        // ── Encoder forward pass ──────────────────────────────────────────

        let inputArray  = try MLMultiArray(shape: [1, seqLen as NSNumber], dataType: .int32)
        let maskArray   = try MLMultiArray(shape: [1, seqLen as NSNumber], dataType: .int32)

        for i in 0..<seqLen {
            let tokenID: Int32 = i < inputIDs.count ? inputIDs[i] : padID
            let attnBit: Int32 = i < inputIDs.count ? 1 : 0
            inputArray[[0, i] as [NSNumber]] = NSNumber(value: tokenID)
            maskArray[[0, i] as [NSNumber]]  = NSNumber(value: attnBit)
        }

        let encInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids":      MLFeatureValue(multiArray: inputArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ])
        let encOutput = try bundle.encoder.prediction(from: encInput)

        guard let hiddenStates = encOutput.featureValue(for: "encoder_hidden_states")?.multiArrayValue else {
            throw OpusMTError.inferenceFailed("encoder_hidden_states feature missing")
        }

        // ── Greedy decoder loop ───────────────────────────────────────────

        let bosID = bundle.tokenizer.bosID
        let eosID = bundle.tokenizer.eosID

        // Hidden state shape: [1, seqLen, hiddenSize]
        let hiddenSize = hiddenStates.shape[2].intValue

        var decoderInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
        decoderInput[[0, 0] as [NSNumber]] = NSNumber(value: bosID)

        var outputIDs = [Int32]()
        outputIDs.reserveCapacity(Self.maxOutputTokens)

        for step in 0..<Self.maxOutputTokens {
            let decInput = try MLDictionaryFeatureProvider(dictionary: [
                "decoder_input_ids": MLFeatureValue(multiArray: decoderInput),
                "encoder_hidden":    MLFeatureValue(multiArray: hiddenStates),
                "encoder_mask":      MLFeatureValue(multiArray: maskArray),
            ])
            let decOutput = try bundle.decoder.prediction(from: decInput)

            guard let logits = decOutput.featureValue(for: "logits")?.multiArrayValue else {
                throw OpusMTError.inferenceFailed("logits feature missing from decoder at step \(step)")
            }

            // logits shape: [1, 1, vocab_size] — greedy argmax over vocab dim.
            let vocabSize = logits.shape[2].intValue
            var bestID: Int32 = 0
            var bestVal: Float = -Float.infinity
            let ptr = UnsafePointer<Float>(OpaquePointer(logits.dataPointer))
            for v in 0..<vocabSize {
                let val = ptr[v]
                if val > bestVal { bestVal = val; bestID = Int32(v) }
            }

            if bestID == eosID { break }
            outputIDs.append(bestID)

            // Feed predicted token as next decoder input.
            decoderInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
            decoderInput[[0, 0] as [NSNumber]] = NSNumber(value: bestID)
        }

        guard !outputIDs.isEmpty else { return text }
        let translated = bundle.tokenizer.decode(outputIDs)
        return translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : translated
    }

    // ── argmax helper ─────────────────────────────────────────────────────

    // (Inlined above for performance — no heap allocation on the hot path.)

    // ── Utilities ─────────────────────────────────────────────────────────

    /// Extract the primary language subtag from a BCP-47 tag.
    /// "pt-BR" → "pt", "de-AT" → "de", "uk" → "uk".
    private func primaryLanguageTag(_ locale: String) -> String {
        guard let sep = locale.firstIndex(where: { $0 == "-" || $0 == "_" }) else {
            return locale.lowercased()
        }
        return String(locale[..<sep]).lowercased()
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - xLMEngine  (public façade)
// ═══════════════════════════════════════════════════════════════════════════
//
// Two entry points. They must never be swapped.
// @MainActor: translateUI requires TranslationSession (MainActor-isolated).

@MainActor
final class xLMEngine {

    static let shared = xLMEngine()

    // Injected by the SwiftUI .translationTask modifier on the root view.
    // Used ONLY by translateUI. Never passed to translateMedical.
    // UI_ONLY — never pass clinical data here.
    var uiTranslationSession: TranslationSession?

    // ──────────────────────────────────────────────────────────────────────
    // PRIMARY: Medical content — opus-mt CoreML, strictly on-device
    // ──────────────────────────────────────────────────────────────────────
    //
    // INPUT CONTRACT:
    //   `text` must be the canonical English label returned by TerminologyMapper.
    //   It MUST NOT be:
    //     • A raw clinical code (ICD-10, LOINC, SNOMED, ATC)
    //     • A patient name, DOB, or national ID
    //     • Any field read directly from a FHIR resource or openEHR Composition
    //     • Any string longer than 200 characters
    //
    // NETWORK: ZERO — all inference is on-device via CoreML.

    func translateMedical(_ text: String, to lang: String) async -> String {
        // Debug-build guard: catch obvious misuse (bare clinical codes) early.
        // This does NOT replace the contract above — it is a last-resort trap.
        assertNoClinicalCode(text, calledFrom: "translateMedical")

        do {
            return try await OpusMTEngine.shared.translate(text, lang: lang)
        } catch {
            // Medical translation failure is non-fatal: fall back to English.
            // The user sees the English label rather than an error.
            // Do NOT fall back to translateUI — medical content stays on-device.
            return text
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // SECONDARY: UI strings only — Apple Translation framework
    // UI_ONLY — never pass clinical data here.
    // ──────────────────────────────────────────────────────────────────────
    //
    // Permitted inputs:
    //   • Button labels:     "Save", "Cancel", "Share"
    //   • Navigation titles: "Health Records", "Emergency Card"
    //   • Error messages:    "Unable to connect. Please retry."
    //   • Section headers:   "Recent Activity", "Settings"
    //
    // STRICTLY FORBIDDEN inputs (use translateMedical instead):
    //   • Diagnosis names, medication names, lab value labels
    //   • Any content derived from TerminologyMapper
    //   • Any FHIR resource field value
    //
    // NETWORK: Apple Translation may call Apple servers. That is acceptable
    //   ONLY because this path never receives patient-identifiable content.

    func translateUI(_ text: String, to lang: String) async -> String {
        // UI_ONLY - never pass clinical data here.
        // Debug-build guard: if this ever receives a clinical code pattern,
        // that is a critical architecture violation.
        assertNoClinicalCode(text, calledFrom: "translateUI")

        guard let session = uiTranslationSession else { return text }
        return (try? await session.translate(text).targetText) ?? text
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Debug guards
    // ──────────────────────────────────────────────────────────────────────

    /// Detects patterns that strongly suggest a clinical code was passed
    /// instead of a display label. Fires assertionFailure in DEBUG builds.
    ///
    /// This is a best-effort heuristic, not a complete validator.
    /// The real guard is the caller contract documented above.
    private func assertNoClinicalCode(_ text: String, calledFrom fn: String) {
        #if DEBUG
        // ICD-10 pattern:  letter + 2 digits, optionally dot + suffix  (e.g. "E11.9")
        let icd10 = #"^[A-Z]\d{2}(\.\d{1,4})?$"#
        // LOINC pattern:   digits dash digits                          (e.g. "4548-4")
        let loinc = #"^\d{1,5}-\d$"#
        // ATC pattern:     letter + digit + letter + digit + 2 digits  (e.g. "A10BA02")
        let atc   = #"^[A-Z]\d{2}[A-Z]{2}\d{2}$"#
        // SNOMED: long numeric string                                  (e.g. "764146007")
        let snomed = #"^\d{6,18}$"#

        for pattern in [icd10, loinc, atc, snomed] {
            if text.range(of: pattern, options: .regularExpression) != nil {
                assertionFailure("""
                    ⚠️  ARCHITECTURE VIOLATION in \(fn):
                    A string matching a clinical code pattern was passed to the
                    translation engine. Clinical codes must never be translated —
                    only the English display labels from TerminologyMapper.
                    Offending string: '\(text)'
                    Pattern matched:  \(pattern)
                    """)
            }
        }
        #endif
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - LocalizedTerminology  (the only sanctioned call site)
// ═══════════════════════════════════════════════════════════════════════════
//
// This is the single approved path for converting a clinical code to a
// localised display string:
//
//   clinical code
//       ↓
//   TerminologyMapper.englishLabel()   [static lookup, zero network]
//       ↓
//   LocalizedTerminology.label()
//       ↓
//   xLMEngine.translateMedical()       [opus-mt CoreML, zero network]
//       ↓
//   localised display label            [shown to user]
//
// No other code path may call translateMedical() or translateUI() with
// content originating from a clinical code or FHIR resource field.

@MainActor
enum LocalizedTerminology {

    /// Resolves a clinical code to a localised display label.
    ///
    /// - Parameters:
    ///   - code:           The clinical code (ICD-10, LOINC, ATC, SNOMED).
    ///   - system:         The coding system the code belongs to.
    ///   - targetLanguage: BCP-47 locale (e.g. "de", "uk", "pt-BR").
    /// - Returns: Translated display label, or the English label if the
    ///            target language is English or translation is unavailable.
    static func label(
        code: String,
        system: TerminologyMapper.TerminologySystem,
        targetLanguage: String
    ) async -> String {
        // Step 1: code → canonical English label (static, zero network).
        let english = TerminologyMapper.englishLabel(code: code, system: system)

        // Step 2: English-speaking locales skip translation entirely.
        guard !targetLanguage.hasPrefix("en") else { return english }

        // Step 3: English label → translated label (opus-mt CoreML, zero network).
        // translateMedical() never falls through to Apple Translation.
        return await xLMEngine.shared.translateMedical(english, to: targetLanguage)
    }
}
