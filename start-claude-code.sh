#!/bin/bash
# #nobordershealthcare — Claude Code startup script
# Run this to begin a session in any module

echo "═══════════════════════════════════════════"
echo "  #nobordershealthcare — Claude Code setup"
echo "═══════════════════════════════════════════"

# 1. Install Claude Code if needed
if ! command -v claude &> /dev/null; then
  echo "Installing Claude Code..."
  npm install -g @anthropic-ai/claude-code
fi

# 2. Show available modules
echo ""
echo "Choose a module to work on:"
echo "  1. /contracts    — Smart contract (START HERE)"
echo "  2. /backend/anonymizer — Core token service"
echo "  3. /backend/gatekeeper — Auth gateway"
echo "  4. /backend/normalization — FHIR/openEHR engine"
echo "  5. /ios          — Swift wallet app"
echo "  6. /infra        — k8s + Terraform"
echo ""
echo "Usage:"
echo "  cd <module> && claude"
echo ""
echo "First session in a module — run this in Claude Code:"
echo "  /init            # initialize CLAUDE.md if not present"
echo "  /memory          # see what Claude already knows"
echo ""
echo "Recommended first prompts per module:"
echo ""
echo "  [contracts]"
echo '  "Read CLAUDE.md and docs/architecture.md. Generate the Hyperledger'
echo '   Fabric chaincode scaffolding for the HealthContract with all 7'
echo '   functions. Use SHA3-256 for hashing. Include unit tests."'
echo ""
echo "  [anonymizer]"
echo '  "Read CLAUDE.md. Generate the Go anonymizer service. Start with'
echo '   the Redis Lua atomic token factory and the Vault config loader.'
echo '   The in-memory hash→docID map must never touch disk."'
echo ""
echo "  [gatekeeper]"
echo '  "Read CLAUDE.md and docs/architecture.md. Generate the gatekeeper'
echo '   service. Priority: the AuthenticateAndHash function that zeroes'
echo '   plaintext userID from memory immediately after hashing."'
echo ""
echo "  [normalization]"
echo '  "Read CLAUDE.md. Generate the FHIR R4 Search API over ScyllaDB.'
echo '   Start with the ATC medication lookup table (at minimum:'
echo '   Metformin A10BA02, Lisinopril C09AA03, 50 common EU drugs).'
echo '   Then the LOINC lab value mapper."'
echo ""
echo "  [ios]"
echo '  "Read CLAUDE.md. Generate the iOS VaultManager.swift using'
echo '   CryptoKit + Secure Enclave. The master key must be generated'
echo '   inside the Secure Enclave and never exported. Include'
echo '   SecureZeroMemory pattern for all plaintext buffers."'
