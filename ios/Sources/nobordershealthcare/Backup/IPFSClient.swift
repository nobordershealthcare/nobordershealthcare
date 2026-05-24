// IPFS / libp2p shard distribution interface.
// Uploads Shamir shards to N=7 nodes; retrieves by CID for recovery.
// Each shard is Kyber-1024 encapsulated + AES-256-GCM authenticated before upload.
// CIDs (content addresses) are stored locally in Keychain; never on-chain.
//
// Payload layout on IPFS: aesGCMBlob(nonce||ciphertext||tag) || kyberCiphertext

import CryptoKit
import Foundation

struct ShardUploadResult: Sendable {
    let shardID: Int
    let cid: String         // IPFS Content Identifier (CIDv1, base32)
    let nodeURL: String     // multiaddr of the IPFS node that pinned this shard
}

struct ShardDownloadResult: Sendable {
    let shardID: Int
    let encryptedBytes: Data
}

enum IPFSError: Error {
    case uploadFailed(shardID: Int, underlying: Error)
    case downloadFailed(cid: String, underlying: Error)
    case encryptionFailed(Error)
    case decryptionFailed(KyberError)
    case aesDecryptionFailed(Error)
    case insufficientShards(recovered: Int, required: Int)
    case cidStorageFailed(OSStatus)
}

actor IPFSClient {

    static let shared = IPFSClient()

    // Gateway URLs are loaded from config at runtime — never hardcoded.
    private var gateways: [URL] = []
    private let cidAccount = "com.noborders.backup.shard-cids"

    func configure(gateways: [URL]) {
        self.gateways = gateways
    }

    // MARK: - Backup

    // Splits the vault key, encrypts each shard with AES-256-GCM using the Kyber shared secret,
    // uploads to IPFS, and persists the CIDs locally.
    // Payload layout: aesGCMBlob(nonce||ciphertext||tag) || kyberCiphertext
    func backup(vaultKey: Data, recipientPublicKey: KyberPublicKey) async throws {
        let shardSet = try ShamirShard.split(secret: vaultKey)
        var results: [ShardUploadResult] = []

        for shard in shardSet.shards {
            let encapsulated = try KyberOperations.encapsulate(using: recipientPublicKey)
            let symmetricKey = SymmetricKey(data: encapsulated.sharedSecret)
            let sealedBox: AES.GCM.SealedBox
            do {
                sealedBox = try AES.GCM.seal(shard.bytes, using: symmetricKey)
            } catch {
                throw IPFSError.encryptionFailed(error)
            }
            // combined = nonce(12) || ciphertext || tag(16); always non-nil from AES.GCM.seal
            let aesBlob = sealedBox.combined!  // swiftlint:disable:this force_unwrapping
            let payload = aesBlob + encapsulated.ciphertext
            let result = try await uploadToIPFS(shardID: shard.id, payload: payload)
            results.append(result)
        }

        try storeCIDs(results.map { ($0.shardID, $0.cid) })
    }

    // MARK: - Recovery

    // Downloads threshold shards, decrypts with AES-256-GCM, and reconstructs the vault key.
    func recover(privateKey: KyberPrivateKey) async throws -> Data {
        let cids = try loadCIDs()
        var shards: [ShardSet.Shard] = []

        for (shardID, cid) in cids.prefix(ShamirShard.threshold) {
            let downloaded = try await downloadFromIPFS(shardID: shardID, cid: cid)
            let kyberCTSize = Kyber1024.ciphertextBytes
            // Payload layout: aesGCMBlob(nonce||ct||tag) || kyberCiphertext
            let aesGCMBlob = downloaded.encryptedBytes.prefix(downloaded.encryptedBytes.count - kyberCTSize)
            let kyberCT = downloaded.encryptedBytes.suffix(kyberCTSize)

            let sharedSecret: Data
            do {
                sharedSecret = try KyberOperations.decapsulate(ciphertext: Data(kyberCT), using: privateKey)
            } catch let e as KyberError {
                throw IPFSError.decryptionFailed(e)
            }

            let symmetricKey = SymmetricKey(data: sharedSecret)
            let decryptedBytes: Data
            do {
                let sealedBox = try AES.GCM.SealedBox(combined: Data(aesGCMBlob))
                decryptedBytes = try AES.GCM.open(sealedBox, using: symmetricKey)
            } catch {
                throw IPFSError.aesDecryptionFailed(error)
            }
            shards.append(ShardSet.Shard(id: shardID, bytes: decryptedBytes))
        }

        guard shards.count >= ShamirShard.threshold else {
            throw IPFSError.insufficientShards(recovered: shards.count, required: ShamirShard.threshold)
        }
        return try ShamirShard.reconstruct(shards: shards)
    }

    // MARK: - IPFS network (stubs — integrate libp2p or an IPFS HTTP API)

    private func uploadToIPFS(shardID: Int, payload: Data) async throws -> ShardUploadResult {
        guard let gateway = gateways.first else {
            throw IPFSError.uploadFailed(shardID: shardID, underlying: URLError(.badURL))
        }
        // POST /api/v0/add to IPFS HTTP API
        var request = URLRequest(url: gateway.appendingPathComponent("api/v0/add"))
        request.httpMethod = "POST"
        request.httpBody = payload
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = json["Hash"] as? String
        else { throw IPFSError.uploadFailed(shardID: shardID, underlying: URLError(.cannotParseResponse)) }
        return ShardUploadResult(shardID: shardID, cid: cid, nodeURL: gateway.absoluteString)
    }

    private func downloadFromIPFS(shardID: Int, cid: String) async throws -> ShardDownloadResult {
        guard let gateway = gateways.first else {
            throw IPFSError.downloadFailed(cid: cid, underlying: URLError(.badURL))
        }
        let url = gateway.appendingPathComponent("ipfs/\(cid)")
        let (data, _) = try await URLSession.shared.data(from: url)
        return ShardDownloadResult(shardID: shardID, encryptedBytes: data)
    }

    // MARK: - CID persistence

    private func storeCIDs(_ pairs: [(Int, String)]) throws {
        let dict = Dictionary(uniqueKeysWithValues: pairs.map { (String($0.0), $0.1) })
        let data = try JSONSerialization.data(withJSONObject: dict)
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     cidAccount,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw IPFSError.cidStorageFailed(status) }
    }

    private func loadCIDs() throws -> [(Int, String)] {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: cidAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw IPFSError.cidStorageFailed(status) }
        return dict.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
    }
}
