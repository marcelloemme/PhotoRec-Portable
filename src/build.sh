#!/bin/bash
# Costruisce "PhotoRec Portable.app" — bundle autonomo con i binari photorec inclusi.
# Non richiede Xcode (solo Command Line Tools) né Homebrew.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # cartella testdisk-7.2-WIP
APP="$ROOT/PhotoRec Portable.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
BIN="$RES/bin"

echo "==> Pulizia bundle precedente"
rm -rf "$APP"
mkdir -p "$MACOS" "$BIN"

echo "==> Compilazione app SwiftUI"
# Compilo universale (arm64 + x86_64) così parte nativa sia su Apple Silicon che Intel.
swiftc "$HERE/main.swift" "$HERE/ExfatNames.swift" \
    -o "$MACOS/PhotoRecFacile" \
    -target arm64-apple-macosx13.0 \
    -parse-as-library \
    -O

echo "==> Copia Info.plist"
cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

echo "==> Copia binari PhotoRec dentro il bundle"
cp "$ROOT/photorec"  "$BIN/photorec"
cp "$ROOT/testdisk"  "$BIN/testdisk"
[ -f "$ROOT/fidentify" ] && cp "$ROOT/fidentify" "$BIN/fidentify" || true
chmod +x "$BIN/"*

echo "==> Traduzioni (en/it)"
for lang in en it; do
    if [ -f "$HERE/$lang.lproj/Localizable.strings" ]; then
        mkdir -p "$RES/$lang.lproj"
        cp "$HERE/$lang.lproj/Localizable.strings" "$RES/$lang.lproj/Localizable.strings"
    fi
done

echo "==> Icona (se disponibile)"
if [ -f "$ROOT/icons/testdisk.icns" ]; then
    cp "$ROOT/icons/testdisk.icns" "$RES/AppIcon.icns"
fi

echo "==> Firma ad-hoc (permette l'apertura dopo option+click → Apri)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign ad-hoc non riuscita, non è bloccante)"

echo ""
echo "FATTO ✅  App creata in:"
echo "   $APP"
echo ""
echo "Per aprirla la prima volta: click destro (o Ctrl+click) sull'app → Apri → Apri."
