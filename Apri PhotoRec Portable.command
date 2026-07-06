#!/bin/bash
#
# "Apri PhotoRec Portable" — sblocca l'app dalla quarantena di macOS e la avvia.
#
# Perché serve: PhotoRec Portable non è firmata con un certificato Apple a pagamento.
# Quando la scarichi, macOS la mette in "quarantena" e (soprattutto su macOS Tahoe/26)
# si rifiuta di aprirla con un semplice doppio click. Questo script rimuove la
# quarantena SOLO da PhotoRec Portable e poi la apre. Non tocca nient'altro.
#
# Come si usa: tieni questo file nella stessa cartella di "PhotoRec Portable.app",
# poi fai doppio click su questo file. Al primo avvio il Terminale chiede conferma:
# conferma e basta.
#
# ---
# "Open PhotoRec Portable" — removes macOS quarantine from the app and launches it.
# PhotoRec Portable isn't signed with a paid Apple certificate, so macOS quarantines
# it on download and (especially on macOS Tahoe/26) refuses to open it on a double
# click. This script removes the quarantine from PhotoRec Portable only, then opens it.
# Keep this file next to "PhotoRec Portable.app" and double-click it.

# Cartella in cui si trova questo script (gestisce spazi e percorsi strani).
DIR="$(cd "$(dirname "$0")" && pwd)"

# Nome dell'app da sbloccare (accetta anche eventuali copie tipo "PhotoRec Portable 2.app").
APP=""
for candidate in "$DIR"/PhotoRec\ Portable*.app; do
    if [ -d "$candidate" ]; then APP="$candidate"; break; fi
done

echo ""
if [ -z "$APP" ]; then
    echo "❌  Non trovo \"PhotoRec Portable.app\" in questa cartella."
    echo "    Metti questo file nella stessa cartella dell'app e riprova."
    echo ""
    echo "    (EN) Couldn't find \"PhotoRec Portable.app\" next to this file."
    echo "    Put this file in the same folder as the app and try again."
    echo ""
    read -n 1 -s -r -p "Premi un tasto per chiudere…"
    exit 1
fi

echo "🔓  Sblocco \"$(basename "$APP")\"…"
echo "    (EN) Unlocking \"$(basename "$APP")\"…"

# Rimuovo la quarantena (ricorsivo su tutto il bundle). L'errore è ignorato se già pulita.
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null

echo "✅  Fatto! Avvio l'app…"
echo "    (EN) Done! Launching the app…"
echo ""

# Apro l'app.
/usr/bin/open "$APP"

# Chiudo automaticamente la finestra del Terminale dopo un attimo.
sleep 1
exit 0
