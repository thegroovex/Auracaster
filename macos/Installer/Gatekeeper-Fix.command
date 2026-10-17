#!/bin/bash
# Auracaster – Gatekeeper-Fix
# Entfernt das Quarantäne-Attribut, das macOS an alles hängt, was aus dem Internet kommt.
# Auracaster ist (noch) nicht von Apple notarisiert; ohne diesen Schritt meldet macOS
# „kann nicht geöffnet werden“ bzw. „ist beschädigt“.
APP="/Applications/Auracaster.app"
clear
printf '\n  \033[1mAuracaster – Gatekeeper-Fix\033[0m\n\n'
if [ ! -d "$APP" ]; then
  printf '  ✗ %s wurde nicht gefunden.\n\n' "$APP"
  printf '    Bitte zuerst im Auracaster-Fenster das App-Symbol auf den Ordner\n'
  printf '    „Programme“ ziehen und dieses Skript danach erneut öffnen.\n\n'
  read -r -n 1 -p "  Taste drücken zum Schließen …"
  exit 1
fi
printf '  1/2  Entferne Quarantäne-Markierung von %s …\n' "$APP"
if ! xattr -dr com.apple.quarantine "$APP" 2>/dev/null; then
  printf '       Dafür braucht macOS dein Anmeldepasswort (Eingabe bleibt unsichtbar):\n'
  sudo xattr -dr com.apple.quarantine "$APP" || { printf '  ✗ Abgebrochen.\n'; exit 1; }
fi
printf '       ✓ erledigt\n'
printf '  2/2  Starte Auracaster …\n'
open "$APP" && printf '       ✓ Auracaster läuft – dieses Fenster kann geschlossen werden.\n\n'
sleep 2
