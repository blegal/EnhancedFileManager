import CryptoKit
import Foundation

/// Numéro de version « 1.2.3 » ou « 1.2.3-dev.4 » (préfixe « v » toléré).
/// Les composants numériques manquants valent 0 ; une préversion précède la version finale.
package struct AppVersion: Comparable, CustomStringConvertible {
    package let numbers: [Int]
    package let prerelease: String?
    package let description: String

    package init(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        description = text
        let parts = text.split(separator: "-", maxSplits: 1)
        numbers = (parts.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    package static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }

    package static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// Dernière release publiée sur GitHub.
package struct Release {
    package let version: AppVersion
    package let title: String
    package let notes: String
    package let page: URL?
    package let dmg: URL?
    package let signature: URL?
}

package enum UpdateError: LocalizedError {
    /// Dépôt privé (jusqu'à la v1.0) ou aucune release : l'API répond 404 sans jeton.
    case unavailable
    case http(Int)
    case missingAsset
    case missingSignature
    case missingPublicKey
    case badSignature
    case appNotFound
    case notWritable(URL)
    case command(String)

    package var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Les mises à jour ne sont pas encore publiées. Le dépôt sera public à partir de la version 1.0 ; en attendant, téléchargez les nouvelles versions à la main."
        case .http(let code): return "Le serveur des mises à jour a répondu par une erreur (\(code))."
        case .missingAsset: return "La dernière version ne contient pas d’image disque pour cette application."
        case .missingSignature: return "La dernière version n’est pas signée : installez-la à la main depuis la page de la version."
        case .missingPublicKey: return "Cette copie de l’application ne contient pas de clé de vérification des mises à jour."
        case .badSignature: return "La signature de l’image disque est invalide : le fichier a été modifié ou corrompu. La mise à jour est abandonnée."
        case .appNotFound: return "L’image disque ne contient pas l’application attendue."
        case .notWritable(let url): return "Impossible de remplacer l’application : vous n’avez pas le droit d’écrire dans « \(url.path) »."
        case .command(let message): return message
        }
    }
}

package enum ReleaseFeed {
    /// Interroge l'API GitHub. `asset` : préfixe du nom de l'image disque (ex. « EnhancedFileManager- »).
    package static func latest(repository: String, assetPrefix: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.unavailable }
        guard status == 200 else { throw UpdateError.http(status) }
        return try parse(data, assetPrefix: assetPrefix)
    }

    package static func parse(_ data: Data, assetPrefix: String) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let dmg = payload.assets.first { $0.name.hasPrefix(assetPrefix) && $0.name.hasSuffix(".dmg") }
        let signature = dmg.flatMap { dmg in payload.assets.first { $0.name == dmg.name + ".sig" } }
        return Release(version: AppVersion(payload.tag_name),
                       title: payload.name ?? payload.tag_name,
                       notes: payload.body ?? "",
                       page: payload.html_url,
                       dmg: dmg?.browser_download_url,
                       signature: signature?.browser_download_url)
    }
}

/// Signature Ed25519 des images disque : la clé privée reste dans les secrets GitHub,
/// la clé publique (32 octets en base64) est embarquée dans Info.plist (clé `UpdatePublicKey`).
package enum UpdateSignature {
    /// `signature` : contenu du fichier .sig (signature en base64, espaces tolérés).
    package static func isValid(file: URL, signature: Data, publicKey: String) throws -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw UpdateError.missingPublicKey
        }
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text) else { return false }
        let content = try Data(contentsOf: file, options: .mappedIfSafe)
        return key.isValidSignature(raw, for: content)
    }
}
