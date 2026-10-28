import Foundation

/// Règles copiées dans ~/Library/Application Support/iExplorer/Actions au premier lancement :
/// l'utilisateur les modifie ou les supprime librement ; elles servent aussi d'exemples.
enum DefaultFileActions {
    static let rules: [(file: String, text: String)] = [
        ("makefile.toml", #"""
        # Makefile : une entrée par cible trouvée dans le fichier.
        # Aussi proposé sur un dossier qui contient un Makefile (ou sur le fond du panneau).
        name  = "Makefile"
        icon  = "hammer"
        match = { names = ["Makefile", "makefile", "GNUmakefile", "*.mk"], folderContains = true, count = "one" }
        requires = ["make"]

        [[action]]
        title = "make"
        icon  = "hammer"
        run   = 'make -f "$FILE"'
        in    = "terminal"

        [[list]]
        # Cibles listées par make lui-même (-q : rien n'est exécuté).
        from   = '''make -qp -f "$FILE" 2>/dev/null | awk -F: '/^# Not a target/ { skip = 1; next } /^[a-zA-Z0-9][^$#\/\t=]*:([^=]|$)/ { if (!skip) { split($1, t, " "); for (i in t) print t[i] } } { skip = 0 }' | grep -vxE '(GNU)?[Mm]akefile|.*\.(o|c|h|mk)|.*/.*' | sort -u'''
        title  = "make $ITEM"
        run    = 'make -f "$FILE" "$ITEM"'
        in     = "terminal"
        pinned = ["all", "build", "pdf", "test", "check", "install", "clean"]
        """#),

        ("typst.toml", #"""
        # Typst : compilation en PDF et surveillance.
        name  = "Typst"
        icon  = "doc.richtext"
        match = { extensions = ["typ"] }
        requires = ["typst"]

        [[action]]
        title = "Compiler en PDF"
        icon  = "doc.badge.gearshape"
        run   = 'for f in "$@"; do typst compile "$f" || exit 1; done'
        then  = "reveal $STEM.pdf"

        [[action]]
        title = "Compiler et ouvrir le PDF"
        icon  = "arrow.up.forward.app"
        run   = 'typst compile "$FILE"'
        then  = "open $STEM.pdf"
        count = "one"

        [[action]]
        title = "Surveiller (typst watch)"
        icon  = "eye"
        run   = 'typst watch "$FILE"'
        in    = "terminal"
        count = "one"
        """#),

        ("markdown.toml", #"""
        # Markdown : conversions avec pandoc (brew install pandoc).
        # Le PDF utilise le premier moteur disponible : typst, tectonic, xelatex, pdflatex, wkhtmltopdf, weasyprint.
        name  = "Markdown"
        icon  = "text.document"
        match = { extensions = ["md", "markdown", "mdown", "mkd"] }

        [[action]]
        title    = "Convertir en PDF"
        icon     = "doc.richtext"
        requires = ["pandoc"]
        run      = '''
        engine=""
        for e in typst tectonic xelatex pdflatex wkhtmltopdf weasyprint; do
          command -v $e >/dev/null && { engine=$e; break; }
        done
        if [ -z "$engine" ]; then
          echo "Aucun moteur PDF trouvé. Installez-en un, par exemple : brew install typst"
          exit 1
        fi
        for f in "$@"; do pandoc "$f" --pdf-engine=$engine -o "${f%.*}.pdf" || exit 1; done
        '''
        then = "reveal $STEM.pdf"

        [[action]]
        title    = "Convertir en HTML"
        icon     = "globe"
        requires = ["pandoc"]
        run      = 'for f in "$@"; do pandoc -s --embed-resources --metadata pagetitle="$(basename "${f%.*}")" "$f" -o "${f%.*}.html" || exit 1; done'
        then     = "reveal $STEM.html"

        [[action]]
        title    = "Convertir en Word (.docx)"
        icon     = "doc.text"
        requires = ["pandoc"]
        run      = 'for f in "$@"; do pandoc "$f" -o "${f%.*}.docx" || exit 1; done'
        then     = "reveal $STEM.docx"

        [[action]]
        title    = "Aperçu dans le navigateur"
        icon     = "safari"
        requires = ["pandoc"]
        count    = "one"
        run      = 'out="${TMPDIR:-/tmp}/$STEM.html"; pandoc -s --embed-resources --metadata pagetitle="$STEM" "$FILE" -o "$out" && open "$out"'

        # Proposé seulement quand pandoc manque.
        [[action]]
        title    = "Installer pandoc (Homebrew)"
        icon     = "arrow.down.circle"
        requires = ["brew"]
        missing  = ["pandoc"]
        run      = "brew install pandoc"
        in       = "terminal"
        """#),

        ("latex.toml", #"""
        # LaTeX : compilation avec latexmk (MacTeX).
        name  = "LaTeX"
        icon  = "function"
        match = { extensions = ["tex"] }
        requires = ["latexmk"]

        [[action]]
        title = "Compiler en PDF"
        icon  = "doc.badge.gearshape"
        run   = 'latexmk -pdf -interaction=nonstopmode -halt-on-error "$FILE"'
        then  = "reveal $STEM.pdf"
        count = "one"

        [[action]]
        title = "Compiler en continu (latexmk -pvc)"
        icon  = "eye"
        run   = 'latexmk -pdf -pvc -interaction=nonstopmode "$FILE"'
        in    = "terminal"
        count = "one"

        [[separator]]

        [[action]]
        title   = "Nettoyer les fichiers auxiliaires"
        icon    = "sparkles"
        run     = 'latexmk -c "$FILE"'
        confirm = "Supprimer les fichiers .aux, .log, .fls… produits par latexmk ?"
        count   = "one"
        """#),

        ("images.toml", #"""
        # Images : conversions avec sips, fourni avec macOS.
        name  = "Images"
        icon  = "photo"
        match = { types = ["public.image"] }
        requires = ["sips"]

        [[action]]
        title = "Convertir en JPEG"
        icon  = "photo"
        run   = 'for f in "$@"; do sips -s format jpeg "$f" --out "${f%.*}.jpg" >/dev/null || exit 1; done'

        [[action]]
        title = "Convertir en PNG"
        icon  = "photo"
        run   = 'for f in "$@"; do sips -s format png "$f" --out "${f%.*}.png" >/dev/null || exit 1; done'

        [[action]]
        title = "Convertir en HEIC"
        icon  = "photo"
        run   = 'for f in "$@"; do sips -s format heic "$f" --out "${f%.*}.heic" >/dev/null || exit 1; done'

        [[separator]]

        [[action]]
        title = "Copie réduite (1600 px)"
        icon  = "arrow.down.right.and.arrow.up.left"
        run   = 'for f in "$@"; do sips -Z 1600 "$f" --out "${f%.*}-1600.${f##*.}" >/dev/null || exit 1; done'

        [[action]]
        title   = "Pivoter de 90°"
        icon    = "rotate.right"
        run     = 'for f in "$@"; do sips -r 90 "$f" >/dev/null || exit 1; done'
        confirm = "Les images sont modifiées sur place."
        """#),

        ("videos.toml", #"""
        # Vidéos : avconvert (fourni avec macOS) et ffmpeg s'il est installé.
        name  = "Vidéos"
        icon  = "film"
        match = { types = ["public.movie"] }

        [[action]]
        title = "Compresser en HEVC 1080p"
        icon  = "film"
        requires = ["avconvert"]
        run   = 'for f in "$@"; do avconvert -s "$f" -p PresetHEVC1920x1080 -o "${f%.*}-1080p.mov" --progress || exit 1; done'
        in    = "terminal"

        [[action]]
        title = "Convertir en MP4 (H.264)"
        icon  = "film"
        requires = ["ffmpeg"]
        run   = 'for f in "$@"; do ffmpeg -n -i "$f" -c:v libx264 -crf 23 -preset medium -c:a aac "${f%.*}-h264.mp4" || exit 1; done'
        in    = "terminal"

        [[action]]
        title = "Créer un GIF animé"
        icon  = "photo.stack"
        requires = ["ffmpeg"]
        run   = 'for f in "$@"; do ffmpeg -n -loglevel error -i "$f" -vf "fps=12,scale=640:-1:flags=lanczos" "${f%.*}.gif" || exit 1; done'

        [[action]]
        title = "Extraire l’audio (M4A)"
        icon  = "waveform"
        requires = ["ffmpeg"]
        run   = 'for f in "$@"; do ffmpeg -n -loglevel error -i "$f" -vn -c:a aac "${f%.*}.m4a" || exit 1; done'
        """#),

        ("audio.toml", #"""
        # Audio : afconvert, fourni avec macOS.
        name  = "Audio"
        icon  = "waveform"
        match = { types = ["public.audio"] }
        requires = ["afconvert"]

        [[action]]
        title = "Convertir en M4A (AAC)"
        run   = 'for f in "$@"; do afconvert -f m4af -d aac "$f" "${f%.*}.m4a" || exit 1; done'

        [[action]]
        title = "Convertir en WAV"
        run   = 'for f in "$@"; do afconvert -f WAVE -d LEI16 "$f" "${f%.*}.wav" || exit 1; done'
        """#),

        ("pdf.toml", #"""
        # PDF : fusion (qpdf) et compression (Ghostscript), s'ils sont installés.
        name  = "PDF"
        icon  = "doc.richtext"
        match = { extensions = ["pdf"] }

        [[action]]
        title    = "Fusionner les PDF"
        icon     = "doc.on.doc"
        requires = ["qpdf"]
        count    = "many"
        run      = 'qpdf --empty --pages "$@" -- "$DIR/Fusion.pdf"'
        then     = "reveal Fusion.pdf"

        [[action]]
        title    = "Compresser (qualité écran)"
        icon     = "arrow.down.right.and.arrow.up.left"
        requires = ["gs"]
        run      = 'for f in "$@"; do gs -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dNOPAUSE -dBATCH -dQUIET -sOutputFile="${f%.*}-compressé.pdf" "$f" || exit 1; done'
        """#),

        ("scripts.toml", #"""
        # Scripts shell et Python.
        name  = "Script"
        icon  = "terminal"
        match = { extensions = ["sh", "zsh", "bash", "command", "py"] }
        count = "one"

        [[action]]
        title = "Exécuter dans le terminal"
        icon  = "play"
        run   = '''
        case "$EXT" in
          py) python3 "$FILE" ;;
          *)  if [ -x "$FILE" ]; then "$FILE"; else zsh "$FILE"; fi ;;
        esac
        '''
        in    = "terminal"

        [[action]]
        title = "Rendre exécutable"
        icon  = "lock.open"
        run   = 'chmod +x "$@"'
        """#),

        ("swift-package.toml", #"""
        # Paquet Swift (Package.swift), aussi sur le dossier du paquet.
        name  = "Swift"
        icon  = "swift"
        match = { names = ["Package.swift"], folderContains = true, count = "one" }
        requires = ["swift"]

        [[action]]
        title = "swift build"
        run   = "swift build"
        in    = "terminal"

        [[action]]
        title = "swift run"
        run   = "swift run"
        in    = "terminal"

        [[action]]
        title = "swift test"
        run   = "swift test"
        in    = "terminal"
        """#),

        ("npm.toml", #"""
        # Projet Node (package.json) : une entrée par script.
        name  = "npm"
        icon  = "shippingbox"
        match = { names = ["package.json"], folderContains = true, count = "one" }
        requires = ["npm", "node"]

        [[action]]
        title = "npm install"
        run   = "npm install"
        in    = "terminal"

        [[list]]
        from   = '''node -e 'for (const s of Object.keys(require(process.argv[1]).scripts || {})) console.log(s)' "$FILE"'''
        title  = "npm run $ITEM"
        run    = 'npm run "$ITEM"'
        in     = "terminal"
        pinned = ["dev", "start", "build", "test", "lint"]
        """#),

        ("cargo.toml", #"""
        # Projet Rust (Cargo.toml).
        name  = "Cargo"
        icon  = "shippingbox"
        match = { names = ["Cargo.toml"], folderContains = true, count = "one" }
        requires = ["cargo"]

        [[action]]
        title = "cargo build"
        run   = "cargo build"
        in    = "terminal"

        [[action]]
        title = "cargo run"
        run   = "cargo run"
        in    = "terminal"

        [[action]]
        title = "cargo test"
        run   = "cargo test"
        in    = "terminal"

        [[action]]
        title   = "cargo clean"
        run     = "cargo clean"
        confirm = "Supprimer le dossier target ?"
        """#),

        ("cmake.toml", #"""
        # Projet CMake (CMakeLists.txt) : construction dans build/.
        name  = "CMake"
        icon  = "hammer"
        match = { names = ["CMakeLists.txt"], folderContains = true, count = "one" }
        requires = ["cmake"]

        [[action]]
        title = "Configurer et compiler"
        run   = "cmake -S . -B build && cmake --build build"
        in    = "terminal"

        [[action]]
        title = "Compiler"
        run   = "cmake --build build"
        in    = "terminal"
        """#),

        ("json.toml", #"""
        # JSON : validation et mise en forme avec jq.
        name  = "JSON"
        icon  = "curlybraces"
        match = { extensions = ["json"] }
        requires = ["jq"]

        [[action]]
        title = "Vérifier la syntaxe"
        icon  = "checkmark.seal"
        run   = 'jq empty "$@" && echo "JSON valide."'
        then  = "output"

        [[action]]
        title   = "Mettre en forme"
        icon    = "text.alignleft"
        run     = 'for f in "$@"; do jq . "$f" > "$f.tmp" && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; exit 1; }; done'
        confirm = "Le fichier est réécrit, indenté."
        """#),
    ]

    /// Modèle d'une nouvelle règle.
    static func template(name: String, extensions: [String]) -> String {
        let list = extensions.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"""
        # \#(name) — actions du menu contextuel.
        # Variables : $FILE, $DIR, $NAME, $STEM, $EXT, $OTHER (autre panneau), "$@" (tous les fichiers sélectionnés).
        name  = "\#(name)"
        icon  = "bolt"
        match = { extensions = [\#(list)] }
        # match peut aussi donner names = ["Makefile", "*.mk"], types = ["public.image"],
        # folderContains = true et count = "one" | "many" | "any".

        [[action]]
        title = "Afficher la taille"
        run   = 'du -h "$@"'
        in    = "background"   # terminal, background ou open
        then  = "output"       # output, refresh, reveal <fichier> ou open <fichier>

        """#
    }
}
