// SentencePieceShim.swift
//
// Stub implementations of the C symbols that SentencePieceTokenizer
// (in xLMEngine.swift) calls through.  These replace the sentencepiece-ios
// xcframework so the target compiles with `dependencies: []`.
//
// At runtime on the simulator the tokeniser always returns empty sequences,
// which makes OpusMT fall back to the English passthrough path — correct
// behaviour while the real models are loaded via On-Demand Resources.
//
// To integrate the real xcframework later:
//   1. Add it to the Frameworks/ folder.
//   2. Add a framework dependency to project.yml.
//   3. Delete this file.

import Foundation

// Opaque handle type that matches the C typedef in sentencepiece-ios.
typealias SPMHandle = OpaquePointer

// MARK: - Stub C functions

func spm_load(_ path: String!) -> OpaquePointer? {
    // Real implementation: OpaquePointer(sentencepiece_processor_new(path))
    return nil
}

func spm_free(_ handle: OpaquePointer!) {
    // Real implementation: sentencepiece_processor_free(handle)
}

func spm_bos_id(_ handle: OpaquePointer!) -> Int32 {
    return 1   // Standard BOS token id for Helsinki-NLP opus-mt models
}

func spm_eos_id(_ handle: OpaquePointer!) -> Int32 {
    return 2   // Standard EOS token id
}

func spm_encode(
    _ handle: OpaquePointer!,
    _ text: String!,
    _ ids: UnsafeMutablePointer<Int32>!,
    _ maxLen: Int32,
    _ count: UnsafeMutablePointer<Int32>!
) -> Int32 {
    // Real implementation: calls sentencepiece_processor_encode(...)
    count?.pointee = 0
    return -1  // Non-zero → SentencePieceTokenizer.encode returns []
}

func spm_decode(
    _ handle: OpaquePointer!,
    _ ids: [Int32],
    _ count: Int32,
    _ buf: UnsafeMutablePointer<CChar>!,
    _ bufLen: Int32
) -> Int32 {
    // Real implementation: calls sentencepiece_processor_decode(...)
    buf?.pointee = 0
    return -1  // Non-zero → SentencePieceTokenizer.decode returns ""
}
