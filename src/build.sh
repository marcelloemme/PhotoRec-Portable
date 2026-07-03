#!/bin/bash
# Costruisce "PhotoRec Portable.app" — bundle autonomo con i binari photorec inclusi.
# Non richiede Xcode (solo Command Line Tools) né Homebrew.
#
# Struttura della repo:
#   src/   -> sorgenti (main.swift, Info.plist, en.lproj, it.lproj, questo build.sh)
#   bin/   -> binari photorec/testdisk/fidentify
# L'app viene creata nella radice della repo.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"      # .../src
ROOT="$(cd "$HERE/.." && pwd)"             # radice repo
BINSRC="$ROOT/bin"                         # binari photorec
APP="$ROOT/PhotoRec Portable.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
BIN="$RES/bin"

echo "==> Pulizia bundle precedente"
rm -rf "$APP"
mkdir -p "$MACOS" "$BIN"

echo "==> Compilazione app SwiftUI"
swiftc "$HERE/main.swift" \
    -o "$MACOS/PhotoRecFacile" \
    -target arm64-apple-macosx13.0 \
    -parse-as-library \
    -O

echo "==> Copia Info.plist"
cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

echo "==> Copia binari PhotoRec dentro il bundle"
cp "$BINSRC/photorec"  "$BIN/photorec"
cp "$BINSRC/testdisk"  "$BIN/testdisk"
[ -f "$BINSRC/fidentify" ] && cp "$BINSRC/fidentify" "$BIN/fidentify" || true
chmod +x "$BIN/"*

echo "==> Traduzioni (en/it)"
for lang in en it; do
    if [ -f "$HERE/$lang.lproj/Localizable.strings" ]; then
        mkdir -p "$RES/$lang.lproj"
        cp "$HERE/$lang.lproj/Localizable.strings" "$RES/$lang.lproj/Localizable.strings"
    fi
done

echo "==> Icona (se disponibile)"
if [ -f "$ROOT/icons/AppIcon.icns" ]; then
    cp "$ROOT/icons/AppIcon.icns" "$RES/AppIcon.icns"
fi

echo "==> Firma ad-hoc (permette l'apertura dopo click destro → Apri)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign ad-hoc non riuscita, non è bloccante)"

echo ""
echo "FATTO ✅  App creata in:"
echo "   $APP"
echo ""
echo "Per aprirla la prima volta: click destro (o Ctrl+click) sull'app → Apri → Apri."
