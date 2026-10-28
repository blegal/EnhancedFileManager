# iExplorer

Gestionnaire de fichiers macOS natif (AppKit, Swift) à 1, 2, 3 ou 4 panneaux avec onglets,
dans l’esprit de ForkLift / Path Finder / muCommander. Aucune dépendance externe.
Le mode d'occupation du disque (⌘5) et la mise à jour automatique viennent des bibliothèques `DiskUsageKit` et `UpdateKit`, partagées avec [iBaobab](https://github.com/blegal/iBaobab), l'analyseur d'occupation des disques (paquet SwiftPM `blegal/iBaobab`).

## Compiler et lancer

```bash
./build.sh          # produit build/iExplorer.app
open build/iExplorer.app
```

Nécessite macOS 26+ et Xcode (Swift 6). Seule dépendance : [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) pour le terminal intégré.

Chaque commit poussé incrémente la version (`Tools/bump-version.sh` : 0.2.1 → 0.2.2 et numéro de build + 1 ;
`Tools/bump-version.sh minor` pour passer à 0.3.0).

## Image disque (DMG) et GitHub Actions

```bash
UNIVERSAL=1 VERSION=0.2.0 ./build.sh   # binaire Apple Silicon + Intel, version dans Info.plist
Tools/make-dmg.sh                      # produit build/iExplorer-0.2.0.dmg
```

Le workflow `.github/workflows/release.yml` construit le DMG à chaque push sur `main` (artefact du run, 30 jours) et le publie dans une release GitHub pour chaque tag `v*` :

```bash
git tag v0.2.0 && git push origin v0.2.0
```

**Signature.** Sans compte Apple Developer, l'application est signée ad hoc : elle n'est pas notarisée, donc au premier lancement d'un DMG téléchargé, macOS la bloque. Il faut faire clic droit › Ouvrir (ou Réglages Système › Confidentialité et sécurité › Ouvrir quand même), ou retirer l'attribut de quarantaine :

```bash
xattr -dr com.apple.quarantine "/Applications/iExplorer.app"
```

Facultatif : pour signer avec un certificat stable (auto-signé, ou Developer ID plus tard), ajoutez dans les secrets du dépôt `MACOS_CERTIFICATE_P12` (le .p12 encodé en base64) et `MACOS_CERTIFICATE_PASSWORD`. Une identité stable évite que macOS redemande les autorisations (dossiers, trousseau) après chaque mise à jour.

## Mise à jour automatique

L'application vérifie les nouvelles versions au lancement (au plus une fois par jour) et à la demande par **iExplorer › Rechercher les mises à jour…**. Tout est natif (bibliothèque `UpdateKit` du paquet [iBaobab](https://github.com/blegal/iBaobab)), sans Sparkle :

1. `URLSession` interroge `https://api.github.com/repos/blegal/iExplorer/releases/latest` et compare le tag à `CFBundleShortVersionString` (`0.2.0-dev.5` précède `0.2.0`).
2. Une fenêtre affiche les notes de version (corps de la release) : **Installer**, **Plus tard** ou **Ignorer cette version** (la vérification manuelle propose quand même une version ignorée).
3. Le DMG est téléchargé avec sa progression, puis sa signature Ed25519 (asset `….dmg.sig`) est vérifiée avec CryptoKit et la clé publique embarquée (`UpdatePublicKey` dans `Resources/Info.plist`). Une signature absente ou invalide arrête tout.
4. L'image est montée (`hdiutil attach -nobrowse`), la nouvelle application est copiée à côté de l'ancienne, la session est sauvegardée, puis un petit script détaché attend la fin du processus, échange les paquets et relance l'application. Il faut pouvoir écrire dans le dossier de l'application (sinon, un message le dit).

Le dépôt reste privé jusqu'à la v1.0 : l'API répond alors 404. La vérification au lancement reste silencieuse ; la vérification manuelle explique que les mises à jour ne sont pas encore publiées. Rien à changer le jour où le dépôt devient public.

**Clé de signature (une seule fois).**

```bash
swift Tools/make-update-key.swift
```

Le script affiche la clé privée, à enregistrer dans le secret `UPDATE_SIGNING_KEY` du dépôt (Settings › Secrets and variables › Actions, ou `gh secret set UPDATE_SIGNING_KEY`), et la clé publique, à placer dans `Resources/Info.plist` (clé `UpdatePublicKey`). Le workflow signe ensuite chaque DMG avec `Tools/sign-update.swift` et publie la signature avec la release. Sans le secret, la release est publiée sans `.sig` et la mise à jour automatique la refuse. Si la clé privée est perdue, les copies déjà installées devront être mises à jour à la main une fois.

## Raccourcis

| Action | Raccourci |
|---|---|
| Copier / Couper / Coller | ⌘C / ⌘X / ⌘V |
| Déplacer les éléments copiés ici | ⌥⌘V |
| Dupliquer | ⌘D |
| Copier vers / déplacer vers l’autre panneau | F5 / F6 |
| Renommer | F2 |
| Renommer par lot (plusieurs éléments) | F2 ou ⌃⌘R |
| Placer dans la corbeille | ⌘⌫ |
| Annuler / Rétablir | ⌘Z / ⇧⌘Z |
| Nouveau dossier | ⇧⌘N |
| Ouvrir | ↩ ou ⌘↓ |
| Dossier parent | ⌫ ou ⌘↑ |
| Précédent / Suivant | ⌘[ / ⌘] (appui long sur les boutons : historique) |
| Dossiers récents | Aller › Dossiers récents |
| Coup d’œil | Espace ou ⌘Y |
| Taille des dossiers sélectionnés / de tous les dossiers | ⌥Espace / ⇧⌥Espace |
| Panneau suivant / précédent | ⇥ / ⇧⇥ |
| 1, 2, 3, 4 panneaux | ⌥⌘1 … ⌥⌘4 |
| Nouvel onglet / fermer l’onglet | ⌘T / ⌘W |
| Onglet suivant / précédent | ⌃⇥ / ⌃⇧⇥ |
| Fichiers cachés | ⇧⌘. |
| Icônes / Liste / Liste détaillée / Colonnes | ⌘1 / ⌘2 / ⌘3 / ⌘4 |
| Navigation synchronisée des panneaux | ⌃⌘Y |
| Ajouter aux favoris | ⌃⌘T |
| Occupation du disque (activer / quitter) | ⌘5 (Échap pour quitter) |
| Zoom (icônes ou liste) | ⌘ + molette, pincement, ⌘+ / ⌘− |
| Taille par défaut | ⌘0 |
| Trier par nom, taille, date, type | ⌃⌥⌘1 … ⌃⌥⌘4 |
| Inspecteur (aperçu, infos, permissions) | ⌥⌘I |
| Compresser / Décompresser ici | ⌥⌘K / ⌥⌘E |
| Décompresser vers l’autre panneau | ⇧⌥⌘E |
| Aller au dossier | ⇧⌘G |
| Rechercher (ce dossier, sous-dossiers, contenu) | ⌘F, Échap pour fermer |
| Même dossier dans l’autre panneau | ⌘= |
| Comparer et synchroniser les panneaux | ⌃⌘C |
| Se connecter au serveur (SFTP, SMB, AFP, NFS, WebDAV) | ⌘K |
| Terminal intégré | ⌃` |
| État Git dans les panneaux | ⌃⌘G |

Glisser-déposer : déplacement sur le même volume, copie vers un autre volume ;
maintenir ⌥ pour forcer la copie, ⌘ pour forcer le déplacement.
Le presse-papiers est partagé avec le Finder.

## Serveurs

- **SFTP** : via l’outil `sftp` du système (aucune bibliothèque externe). Authentification par clé
  (agent ssh, `~/.ssh/config`, ou clé choisie dans le panneau de connexion) ou par mot de passe,
  demandé par l’app et éventuellement rangé dans le trousseau. Une seule authentification par serveur
  (connexion maîtresse partagée). Pas de corbeille côté serveur : la suppression est définitive (confirmée).
- **SMB, AFP, NFS, WebDAV** : montage natif (NetFS) dans `/Volumes`.
- Les connexions enregistrées apparaissent dans la section « Réseau » de la barre latérale
  (clic droit : se connecter, modifier, supprimer).

## Barre latérale

La section « Favoris » est modifiable, comme dans le Finder. Elle part des favoris du Finder (ou, si macOS en
refuse la lecture, des dossiers standard), puis :

- ajouter un dossier : ⌃⌘T, clic droit › Ajouter aux favoris, ou glisser un dossier entre deux favoris ;
- réordonner : glisser un favori à sa nouvelle place ;
- retirer : clic droit › Retirer de la barre latérale ;
- clic droit sur l’en-tête « Favoris » › Rétablir les favoris par défaut.

Déposer des fichiers *sur* un favori les copie ou les déplace dans ce dossier.

Section « Appareils » : chaque volume local affiche une jauge d’occupation (bleue, orange au-delà de 80 %,
rouge au-delà de 92 %) et l’espace libre ; bouton d’éjection pour les volumes amovibles et les images disque ;
clic droit › Analyser l’espace disque ou Éjecter. « Monter une image disque… » (ou clic droit sur un .dmg, .iso…
dans un panneau › Monter l’image disque) monte l’image avec `hdiutil` et ouvre le volume.

## Thèmes d’icônes

Présentation › Thème d’icônes : Système (macOS) ou l’un des dix thèmes (Matériau coloré, Catppuccin pastel,
Seti minimal, Trait fin, Duotone, Fluent doux, Badges d’extension, Nord givré, Papirus plat, Néon Dracula).
Les dessins sont originaux et vectoriels, inspirés du style des jeux open source cités ; ils suivent
automatiquement l’apparence claire ou sombre. Les applications et paquets gardent leur icône système.

## Git

Bouton « Git » de la barre d’outils (désactivé par défaut, car il lance `git status`) :
noms colorés comme dans VS Code (modifié, non suivi, supprimé, conflit, ignoré) avec la lettre d’état,
dossiers colorés selon leur contenu, et pour chaque dossier qui est un dépôt : ● modifications non validées,
↑ commits à pousser, ↓ commits à tirer (d’après le dernier `git fetch`, aucun accès réseau automatique).
Mise à jour automatique via FSEvents.

Dans l’inspecteur, section Git de l’élément sélectionné : état, indexer / désindexer / abandonner les
modifications, valider, récupérer, tirer, pousser ; diff coloré et historique du fichier. Les phrases de
passe SSH et identifiants HTTPS sont demandés par l’app (même fenêtre que pour SFTP).

## Terminal

Terminal intégré en bas de la fenêtre (SwiftTerm), avec votre shell. Il suit le dossier du panneau actif
(bouton 🔗) uniquement quand le shell est au repos : il n’interrompt jamais un programme en cours.

## Session

Une seule fenêtre principale. À la fermeture sont mémorisés : position de la fenêtre, disposition et
positions des séparateurs, panneau actif, onglets et dossiers de chaque panneau, mode d’affichage,
taille des icônes, tri, barre latérale, inspecteur, terminal, thème d’icônes, fichiers cachés et Git.
Les onglets SFTP ne sont pas rouverts (ils demanderaient une connexion au lancement).

## Thèmes de couleurs

Bouton « Thème de couleurs » de la barre d’outils (ou Présentation › Thème de couleurs) : Système (macOS) ou
l’un des 12 thèmes, en trois familles — Uni (Graphite neutre, Ardoise bleutée, Sable chaud, Encre profonde),
Uni par zones (Établi, Atelier, Nord, Solarisé) et Non uni (Verre liquide, Aurore, Papier grainé, Brume).
Chaque thème a une variante claire et sombre qui suit l’apparence du système.

## Icône

`Tools/set-app-icon.sh A|B|C|D` choisit l’icône de l’app parmi les propositions (dessinées par
`Tools/make-icons.swift`), puis `./build.sh`.

## Favoris du Finder

Si la section Favoris ne montre pas vos favoris du Finder, utilisez Aide › Diagnostic des favoris du Finder :
macOS peut exiger l’« Accès complet au disque » pour lire leur liste.

## Onglets

La zone des onglets est teintée par l’accent du thème. Clic droit sur un onglet : couleur de l’onglet
(rouge, orange, jaune, vert, bleu, violet, gris), mémorisée avec la session.

## Menu contextuel

Les actions courantes (couper, copier, coller, dupliquer, renommer, coup d’œil, corbeille) et les sept couleurs
de tags sont des rangées d’icônes en tête du menu contextuel ; le nom de chaque action apparaît en bulle d’aide.

## Vue en colonnes

Comme dans le Finder (⌘4), avec glisser-déposer (vers un dossier ou dans le dossier d’une colonne), couleurs
et lettres d’état Git et pastilles de tags.

## Navigation synchronisée

Bouton « Synchro » de la barre d’outils ou ⌃⌘Y (Aller › Navigation synchronisée) : quand le panneau actif
descend dans un sous-dossier ou remonte, les autres panneaux visibles font le même déplacement relatif depuis
leur propre dossier, en local comme en SFTP. Pratique pour parcourir deux arborescences jumelles. Si le dossier
n’existe pas de l’autre côté, ce panneau reste en place (bip).

## Permissions

Dans l’inspecteur : cases R / W / X, mode octal modifiable (Retour pour appliquer), propriétaire et groupe en
menus, verrouillage, et « Appliquer aux éléments inclus… » pour un dossier. Si macOS refuse (fichiers d’un autre
compte), l’app propose de réessayer avec les droits d’administrateur. En SFTP, les permissions sont lues et
modifiées sur le serveur (`chmod`, `chown`, `chgrp` ; propriétaire et groupe en identifiants numériques).

## Tags du Finder

Pastilles de couleur dans les listes, ligne « Tags » dans l’inspecteur. Clic droit › Tags pour ajouter ou
retirer un tag (annulable). Recherche ⌘F : `tag:Rouge` ou `#Rouge`. Section « Tags » de la barre latérale :
tous les fichiers portant ce tag (Spotlight, dossier personnel).

## Opérations

Chaque copie / déplacement en cours affiche son débit et le temps restant, avec des boutons pause / reprise
et annulation. Fichier › Vérifier les copies : chaque copie est relue et comparée à l’original ; lors d’un
déplacement entre disques, l’original n’est supprimé qu’après vérification.

## Aperçu dans l’inspecteur

Code et texte avec coloration syntaxique (Swift, C/C++, Python, JavaScript/TypeScript, Java/Kotlin, Go, Rust,
shell, JSON, LaTeX, Markdown), PDF feuilletable (PDFKit), vidéo et audio (AVKit), images, et Coup d’œil
intégré pour les autres documents.

## Occupation du disque

⌘5, le bouton à bascule « Occupation » de la barre d’outils (allumé tant que le mode est actif, un second clic revient aux fichiers) ou « Analyser l’espace disque » dans le menu contextuel d’un dossier : le panneau remplace la liste des fichiers par la répartition de l’espace du dossier courant, analysée en arrière-plan (taille réellement occupée sur le disque, sans suivre les liens symboliques ni traverser les autres volumes). La vue par défaut est la **carte épurée** ; sept icônes permettent de basculer entre :

1. carte coussin (relief façon GdMap) ;
2. carte épurée (par défaut) ;
3. soleil (anneaux concentriques) ;
4. partition empilée (une rangée par niveau) ;
5. histogramme des éléments directs, barres réparties par type ;
6. anneau et liste ;
7. liste et soleil façon Baobab (liste dépliable avec barres d’utilisation, survol synchronisé).

Les couleurs suivent le type de fichier, l’ancienneté ou la branche. Un clic sur un dossier y entre (le fil d’Ariane, l’historique et les onglets suivent, sans nouvelle analyse) ; ⌫, ⌘↑ ou le centre du soleil remontent. Le menu contextuel d’un bloc permet de l’ouvrir, de l’afficher dans la liste, dans le Finder ou de le placer dans la corbeille. Pour limiter la mémoire, seuls les 200 plus gros fichiers de chaque dossier sont gardés individuellement, les autres sont regroupés ; l’arbre est libéré en quittant le mode.

## iBaobab

[iBaobab](https://github.com/blegal/iBaobab) est une application à part, dans son propre dépôt (public), dédiée à l'analyse de l'occupation des disques. Son paquet SwiftPM fournit les bibliothèques communes : `DiskUsageKit` (scan, modèle `DiskNode`, les sept graphiques et la page d'analyse du mode ⌘5) et `UpdateKit` (mise à jour automatique, indicateur de la barre d'outils). iExplorer en dépend par `.package(url: "https://github.com/blegal/iBaobab", branch: "main")` ; `swift package update iBaobab` récupère leurs dernières modifications. Pour modifier ces bibliothèques en même temps qu'iExplorer : `swift package edit iBaobab --path ../iBaobab`.

## Actions personnalisées

Menu Actions › Gérer les actions… : commandes shell avec variables (`%chemin`, `%autre`, `%sélection`,
`%fichier`, `%nom`, `%base`, `%ext`, protégées pour le shell), exécutées dans le terminal intégré ou en
arrière-plan, avec raccourci clavier et confirmation optionnels. Disponibles dans le menu Actions et le
clic droit. Exemples fournis : compiler un .tex (latexmk), ouvrir dans VS Code, rsync vers un serveur.
