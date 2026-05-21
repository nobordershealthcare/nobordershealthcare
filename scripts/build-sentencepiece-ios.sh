#!/usr/bin/env bash
# build-sentencepiece-ios.sh — Cross-compile SentencePiece for iOS and produce
# an XCFramework that Swift can consume via a C module map.
#
# Output: ios/Frameworks/sentencepiece-ios.xcframework
#
# Prerequisites (installed via Homebrew on macOS):
#   brew install cmake protobuf abseil
#   Xcode 15.0+ with iOS 16.0+ SDK
#
# Usage:
#   chmod +x scripts/build-sentencepiece-ios.sh
#   ./scripts/build-sentencepiece-ios.sh
#
# What this script produces:
#   ios/Frameworks/sentencepiece-ios.xcframework/
#     ios-arm64/           — real device slice
#       Headers/           — public C header + module map
#       libsentencepiece_ios.a
#     ios-arm64-simulator/ — simulator slice (M-chip Macs)
#       Headers/
#       libsentencepiece_ios.a
#
# The XCFramework bundles both the device and simulator slices so Xcode picks
# the right one automatically (no manual lipo needed).

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
OUTPUT_DIR="${REPO_ROOT}/ios/Frameworks"
BUILD_DIR="${REPO_ROOT}/.build/sentencepiece"

XCFRAMEWORK_NAME="sentencepiece-ios"
XCFRAMEWORK_OUT="${OUTPUT_DIR}/${XCFRAMEWORK_NAME}.xcframework"

# SentencePiece v0.2.0 is the last release that uses the same internal API
# that Helsinki-NLP opus-mt models were trained with.
SPM_TAG="v0.2.0"
SPM_REPO="https://github.com/google/sentencepiece.git"
SPM_SRC="${BUILD_DIR}/sentencepiece-src"

# iOS deployment target — must match Package.swift
IOS_DEPLOYMENT_TARGET="26.0"

# ── Colour helpers ─────────────────────────────────────────────────────────

bold="\033[1m"
green="\033[0;32m"
yellow="\033[0;33m"
red="\033[0;31m"
reset="\033[0m"

info()  { echo -e "${bold}▶${reset} $*"; }
ok()    { echo -e "${green}✔${reset} $*"; }
warn()  { echo -e "${yellow}⚠${reset} $*"; }
die()   { echo -e "${red}✖${reset} $*" >&2; exit 1; }

# ── Preflight checks ───────────────────────────────────────────────────────

info "Checking prerequisites…"

command -v cmake   >/dev/null 2>&1 || die "cmake not found. Install: brew install cmake"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode."

IOS_SDK="$(xcrun --sdk iphoneos   --show-sdk-path 2>/dev/null)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"
[[ -d "${IOS_SDK}" ]] || die "iOS SDK not found. Is Xcode installed?"
[[ -d "${SIM_SDK}" ]] || die "iOS Simulator SDK not found."

ok "Prerequisites OK (cmake $(cmake --version | head -1 | awk '{print $3}'))"

# ── Clean build directory ──────────────────────────────────────────────────
# Always start from scratch to avoid stale CMake cache entries that can mask
# policy errors or pick up the wrong SDK sysroot between runs.

if [[ -d "${BUILD_DIR}" ]]; then
    info "Removing existing build directory for clean build…"
    rm -rf "${BUILD_DIR}"
    ok "Removed ${BUILD_DIR}"
fi

# ── Clone SentencePiece ────────────────────────────────────────────────────

mkdir -p "${BUILD_DIR}"

if [[ ! -d "${SPM_SRC}/.git" ]]; then
    info "Cloning google/sentencepiece ${SPM_TAG} (with submodules)…"
    # Abseil is a submodule — must recurse.
    git clone --depth 1 --branch "${SPM_TAG}" \
        --recurse-submodules --shallow-submodules \
        "${SPM_REPO}" "${SPM_SRC}"
    ok "Clone complete"
else
    info "SentencePiece source already present at ${SPM_SRC}, skipping clone."
fi

# ── Copy wrapper sources into sentencepiece src ────────────────────────────
# The C wrapper is compiled as part of the static library so it shares the
# same compilation unit and can include sentencepiece_processor.h directly.

cp "${SCRIPTS_DIR}/sentencepiece_c_wrapper.h"   "${SPM_SRC}/src/"
cp "${SCRIPTS_DIR}/sentencepiece_c_wrapper.cpp" "${SPM_SRC}/src/"

# ── set_xcode_property stub ────────────────────────────────────────────────
# sentencepiece's CMakeLists.txt calls set_xcode_property() — a macro that
# is only defined when building with the Xcode generator. When using the
# Ninja generator (required for cross-compiling to iOS) CMake errors with:
#   "Unknown CMake command set_xcode_property"
# We inject an empty stub via CMAKE_PROJECT_sentencepiece_INCLUDE so the
# macro is defined before any call site is reached, without modifying the
# upstream source tree.

XCODE_FIX_DIR="${SPM_SRC}/cmake"
mkdir -p "${XCODE_FIX_DIR}"
cat > "${XCODE_FIX_DIR}/xcode_fix.cmake" << 'XCODE_FIX'
# xcode_fix.cmake — stub out set_xcode_property for non-Xcode generators.
# Injected via -DCMAKE_PROJECT_sentencepiece_INCLUDE at configure time.
macro(set_xcode_property TARGET XCODE_PROPERTY XCODE_VALUE)
endmacro()
XCODE_FIX
ok "xcode_fix.cmake stub written to ${XCODE_FIX_DIR}"

# ── Build function ─────────────────────────────────────────────────────────
# CMake 4.x policy fix:
#   CMAKE_POLICY_VERSION_MINIMUM=3.5 tells CMake 4 to apply 3.5 policy
#   defaults when processing projects that declare an older minimum version,
#   rather than hard-erroring. This is the official CMake 4.x migration path.
#   CMAKE_POLICY_DEFAULT_CMP0048=NEW suppresses the related project() warning.

build_slice() {
    local SLICE_NAME="$1"    # e.g. "iphoneos" or "iphonesimulator"
    local ARCH="$2"           # e.g. "arm64"
    local SDK_PATH="$3"       # full path to .sdk
    local EXTRA_FLAGS="$4"    # extra cmake flags (e.g. simulator ABI flag)

    local SLICE_BUILD="${BUILD_DIR}/build-${SLICE_NAME}-${ARCH}"
    local SLICE_INSTALL="${BUILD_DIR}/install-${SLICE_NAME}-${ARCH}"

    info "Building ${SLICE_NAME}/${ARCH}…"
    mkdir -p "${SLICE_BUILD}" "${SLICE_INSTALL}"

    # CMP0048: project() command manages VERSION variables — set NEW to silence
    # the warning that accompanies CMAKE_POLICY_VERSION_MINIMUM.
    export CMAKE_POLICY_DEFAULT_CMP0048=NEW

    cmake -S "${SPM_SRC}" -B "${SLICE_BUILD}" \
        -G "Ninja" \
        -DCMAKE_PROJECT_sentencepiece_INCLUDE=cmake/xcode_fix.cmake \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${SLICE_INSTALL}" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
        -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_C_FLAGS="-fembed-bitcode=off" \
        -DCMAKE_CXX_FLAGS="-fembed-bitcode=off ${EXTRA_FLAGS}" \
        -DENABLE_BITCODE=OFF \
        -DCMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE=NO \
        -DCMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
        -DSP_BUILD_TEST=OFF \
        -DSP_ENABLE_SHARED=OFF \
        -DSPM_BUILD_TEST=OFF \
        -DSPM_BUILD_EXAMPLES=OFF \
        -DSPM_ENABLE_SHARED=OFF \
        -DSPM_USE_BUILTIN_PROTOBUF=ON \
        -DSPM_EXTRA_SOURCES="src/sentencepiece_c_wrapper.cpp" \
        -DSPM_EXTRA_INCLUDES="${SPM_SRC}/src" \
        -Wno-dev \
        2>&1 | grep -E "(error:|warning:|CMake)" | head -40 || true

    cmake --build "${SLICE_BUILD}" --config Release -- -j"$(sysctl -n hw.logicalcpu)"
    cmake --install "${SLICE_BUILD}" --config Release

    # ── Manually compile C wrapper and inject into static lib ─────────────
    # SPM_EXTRA_SOURCES does not reliably add sources when cross-compiling
    # with Ninja on iOS — the wrapper object is silently dropped from the
    # archive.  Compile it explicitly with the same flags and add it with ar.

    local WRAPPER_OBJ="${SLICE_BUILD}/spm_wrapper.o"

    # Derive the correct Clang target triple from the slice being built.
    local CLANG_TARGET
    if [[ "${SLICE_NAME}" == "iphonesimulator" ]]; then
        CLANG_TARGET="${ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
    else
        CLANG_TARGET="${ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
    fi

    info "  Compiling C wrapper for ${CLANG_TARGET}…"
    /usr/bin/clang++ \
        -target "${CLANG_TARGET}" \
        -isysroot "${SDK_PATH}" \
        -fembed-bitcode=off \
        -std=c++17 \
        -I"${SPM_SRC}/src" \
        -c "${SCRIPTS_DIR}/sentencepiece_c_wrapper.cpp" \
        -o "${WRAPPER_OBJ}"

    info "  Adding wrapper object to static lib…"
    ar rcs "${SLICE_INSTALL}/lib/libsentencepiece.a" "${WRAPPER_OBJ}"

    # Verify the symbol landed in the archive.
    if nm "${SLICE_INSTALL}/lib/libsentencepiece.a" 2>/dev/null | grep -q "spm_load"; then
        ok "  ${SLICE_NAME}/${ARCH}: spm_load symbol confirmed in archive"
    else
        die "  ${SLICE_NAME}/${ARCH}: spm_load NOT found after ar — check wrapper compilation"
    fi

    ok "Built ${SLICE_NAME}/${ARCH}: ${SLICE_INSTALL}/lib/libsentencepiece.a"
}

# ── Compile slices ─────────────────────────────────────────────────────────

# Real device slice — arm64
build_slice "iphoneos" "arm64" "${IOS_SDK}" ""

# Simulator slice — arm64 (M-chip Macs).
# The -target flag differentiates device arm64 from simulator arm64.
SIM_TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
build_slice "iphonesimulator" "arm64" "${SIM_SDK}" "-target ${SIM_TARGET}"

# ── Final symbol verification ──────────────────────────────────────────────
# nm check already ran inside build_slice after each ar step.
# This loop is a belt-and-suspenders guard on the installed archives.

info "Final symbol verification…"
for slice in "iphoneos-arm64" "iphonesimulator-arm64"; do
    LIB="${BUILD_DIR}/install-${slice}/lib/libsentencepiece.a"
    if nm "${LIB}" 2>/dev/null | grep -q "spm_load"; then
        ok "  ${slice}: spm_load present ✓"
    else
        die "  ${slice}: spm_load MISSING in final archive — build is broken"
    fi
done

# ── Prepare Headers directory ──────────────────────────────────────────────
# XCFramework needs a Headers/ directory alongside each slice's .a file.
# We include only the public C header + a module map so Swift sees it.

prepare_headers() {
    local INSTALL_DIR="$1"
    local HEADERS_DIR="${INSTALL_DIR}/Headers"
    mkdir -p "${HEADERS_DIR}"

    cp "${SCRIPTS_DIR}/sentencepiece_c_wrapper.h" "${HEADERS_DIR}/"

    # Module map: exposes SentencePieceC as a Swift-importable module.
    cat > "${HEADERS_DIR}/module.modulemap" << 'MODULEMAP'
module SentencePieceC {
    header "sentencepiece_c_wrapper.h"
    export *
}
MODULEMAP

    ok "  Headers prepared in ${HEADERS_DIR}"
}

info "Preparing Headers directories…"
prepare_headers "${BUILD_DIR}/install-iphoneos-arm64"
prepare_headers "${BUILD_DIR}/install-iphonesimulator-arm64"

# ── Assemble XCFramework ───────────────────────────────────────────────────

info "Assembling XCFramework…"
rm -rf "${XCFRAMEWORK_OUT}"
mkdir -p "${OUTPUT_DIR}"

xcodebuild -create-xcframework \
    -library "${BUILD_DIR}/install-iphoneos-arm64/lib/libsentencepiece.a" \
    -headers "${BUILD_DIR}/install-iphoneos-arm64/Headers" \
    -library "${BUILD_DIR}/install-iphonesimulator-arm64/lib/libsentencepiece.a" \
    -headers "${BUILD_DIR}/install-iphonesimulator-arm64/Headers" \
    -output "${XCFRAMEWORK_OUT}"

ok "XCFramework created: ${XCFRAMEWORK_OUT}"

# ── Smoke test ─────────────────────────────────────────────────────────────

info "Verifying XCFramework structure…"

EXPECTED_SLICES=(
    "ios-arm64/libsentencepiece.a"
    "ios-arm64-simulator/libsentencepiece.a"
    "ios-arm64/Headers/sentencepiece_c_wrapper.h"
    "ios-arm64/Headers/module.modulemap"
)

for rel in "${EXPECTED_SLICES[@]}"; do
    if [[ -f "${XCFRAMEWORK_OUT}/${rel}" ]]; then
        ok "  Found: ${rel}"
    else
        warn "  Missing: ${rel}"
    fi
done

# ── Done ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${bold}${green}Build complete!${reset}"
echo ""
echo "Next steps:"
echo "  1. Add the XCFramework to Package.swift:"
echo "     .binaryTarget(name: \"SentencePieceC\","
echo "                   path: \"ios/Frameworks/sentencepiece-ios.xcframework\")"
echo ""
echo "  2. Add 'SentencePieceC' to the nobordershealthcare target dependencies."
echo ""
echo "  3. Import in Swift: import SentencePieceC"
echo "     Then replace the TODO stubs in SentencePieceTokenizer."
echo ""
echo "  4. Run the CoreML conversion script to generate the .mlpackage files:"
echo "     pip install -r scripts/requirements-coreml.txt"
echo "     python scripts/convert-opus-mt-to-coreml.py --lang uk ru de pt"
