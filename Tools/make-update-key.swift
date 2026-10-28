#!/usr/bin/env swift
// Génère la paire de clés Ed25519 qui signe les mises à jour.
//   swift Tools/make-update-key.swift
// - La clé privée va dans le secret GitHub UPDATE_SIGNING_KEY (jamais dans le dépôt).
// - La clé publique va dans Resources/Info.plist (clé UpdatePublicKey) : l'application l'embarque.
// Si la clé privée est perdue, il faut en générer une nouvelle : les copies déjà installées
// (qui ne connaissent que l'ancienne clé publique) devront alors être mises à jour à la main.
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let privateKey = key.rawRepresentation.base64EncodedString()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

print("""
Clé privée (secret, à ne jamais publier) :
  \(privateKey)

Clé publique :
  \(publicKey)

1. Enregistrez la clé privée dans les secrets du dépôt, sous le nom UPDATE_SIGNING_KEY :
   GitHub › Settings › Secrets and variables › Actions › New repository secret,
   ou en ligne de commande (la clé est lue sur l'entrée standard, elle n'apparaît pas dans l'historique) :
     pbpaste | gh secret set UPDATE_SIGNING_KEY --repo blegal/EnhancedFileManager
   (après avoir copié la clé privée). Gardez-en aussi une copie dans votre trousseau.

2. Placez la clé publique dans Resources/Info.plist :
     /usr/libexec/PlistBuddy -c "Set :UpdatePublicKey \(publicKey)" Resources/Info.plist
   puis commitez Info.plist.

Le workflow de release signe alors chaque image disque et publie la signature (.dmg.sig).
""")
