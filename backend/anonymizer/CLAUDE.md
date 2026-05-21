# Anonymizer Service — Module Context

## What this is
The most security-critical backend service. The core innovation.
MUST be stateless between sessions.

## Language: Go 1.22+

## What this service does (exactly, in order)
1. Receives: session_token (JWT) + hash(docID) from client
2. Verifies JWT signature and expiry (Ed25519)
3. Calls gatekeeper: is this role/scope permitted for this docID?
4. Resolves hash(docID) → internal_doc_id
   SOURCE: Vault Agent sidecar injects at pod start → in-memory map
   NEVER written to disk
5. Generates UUID v4 token (OS CSPRNG XOR server entropy, SHA3-256 hash)
6. Redis SET token→cassandra_key EX 300 NX (Lua atomic, no reuse)
7. For media: MinIO pre-signed URL (HMAC, TTL 120s, single-use Redis token)
8. Assembles scope-filtered openEHR/IPS XML in memory
9. Logs hash(requester)+hash(docID) to Fabric audit chain (goroutine)
10. Returns ephemeral_token or pre-signed URL

## Module structure
```
/backend/anonymizer
  main.go
  /config
    vault.go         — Vault Agent sidecar config loader
    config.go        — env vars only, no secrets
  /token
    factory.go       — CSPRNG + entropy mixing + SHA3-256
    redis.go         — Lua atomic SET EX NX, Redis Cluster client
  /resolver
    docid.go         — hash(docID) → internal_doc_id (in-memory map)
    cassandra.go     — ScyllaDB CQL client
  /media
    presigned.go     — MinIO pre-signed URL, HMAC signed
    singleuse.go     — single-use enforcement via Redis
  /xml
    assembler.go     — scope-filtered openEHR/IPS XML builder
    pdf.go           — DRM PDF, watermark = hash(requestor+timestamp)
  /audit
    fabric.go        — fire-and-forget Fabric event log goroutine
  /health
    probe.go         — k8s liveness + readiness
```

## Redis Lua atomic (CRITICAL — copy this exactly)
```go
const luaSetToken = `
local ok = redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2], 'NX')
if ok then return 1 end
return 0
`
// NX = only if Not eXists (prevents token reuse)
// EX = TTL in seconds (max 300)
// Run with redis.NewScript(luaSetToken).Run(ctx, client, keys, args)
```

## What this service MUST NOT do
- MUST NOT write hash→docID map to disk or any database
- MUST NOT log cassandra_row_key or ephemeral token value
- MUST NOT accept without valid mTLS client cert
- MUST NOT start if Vault Agent sidecar is unhealthy
- MUST NOT reuse tokens (NX enforces this at Redis level)

## Pod lifecycle
- Replaced every 10,000 requests OR 1 hour (whichever first)
- k8s annotation: max-requests: "10000"
- On termination: in-memory map lost by design. Active Redis tokens expire naturally.

## Performance targets
- p99 latency: < 50ms
- Throughput: 1,000 req/s per pod
- Scale: 3–20 pods via k8s HPA
