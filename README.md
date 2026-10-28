# Enhanced File Manager

Gestionnaire de fichiers macOS natif (AppKit, Swift) à 1, 2, 3 ou 4 panneaux avec onglets,
dans l’esprit de ForkLift / Path Finder / muCommander. Aucune dépendance externe.

## Compiler et lancer

```bash
./build.sh          # produit build/EnhancedFileManager.app
open build/EnhancedFileManager.app
```

Nécessite macOS 26+ et Xcode (Swift 6). Seule dépendance : [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) pour le terminal intégré.

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
| Icônes / Liste / Liste détaillée | ⌘1 / ⌘2 / ⌘3 |
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

La section « Favoris » reprend les favoris du Finder. Si macOS en refuse la lecture,
une liste par défaut est utilisée (l’accès complet au disque, dans Réglages Système, lève ce blocage).

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

## Tags du Finder

Pastilles de couleur dans les listes, ligne « Tags » dans l’inspecteur. Clic droit › Tags pour ajouter ou
retirer un tag (annulable). Recherche ⌘F : `tag:Rouge` ou `#Rouge`. Section « Tags » de la barre latérale :
tous les fichiers portant ce tag (Spotlight, dossier personnel).
