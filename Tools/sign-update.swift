#!/usr/bin/env swift
// Signe une image disque pour la mise à jour automatique (utilisé par le workflow de release).
//   UPDATE_SIGNING_KEY=<clé privée base64> swift Tools/sign-update.swift build/App-1.0.dmg > build/App-1.0.dmg.sig
// La signature Ed25519 (base64) porte sur le contenu exact du fichier.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage : sign-update.swift <fichier.dmg>\n".utf8))
    exit(2)
}
guard let encoded = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
      let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("UPDATE_SIGNING_KEY absente ou invalide\n".utf8))
    exit(1)
}
let content = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
let signature = try key.signature(for: content)
guard key.publicKey.isValidSignature(signature, for: content) else { exit(1) }
print(signature.base64EncodedString())
