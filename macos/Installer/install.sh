#!/bin/bash
# Auracaster – Installation per Terminal (ohne Gatekeeper-Warnung).
#
#   curl -fsSL https://raw.githubusercontent.com/thegroovex/Auracaster/main/macos/Installer/install.sh | bash
#
# Lädt das neueste Release (ZIP) von GitHub, legt Auracaster.app nach /Applications,
# richtet optional die Funk-Engine ein (Python/Bumble/LC3 über uv) und startet die App.
# Mit curl geladene Dateien bekommen kein Quarantäne-Attribut – daher keine Gatekeeper-Abfrage.
set -euo pipefail
REPO="thegroovex/Auracaster"
DEST="${AURACASTER_DEST:-/Applications}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

printf '\n\033[1m▶ Auracaster wird installiert\033[0m\n'
[ "$(uname -s)" = Darwin ] || { echo "Nur für macOS."; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || echo "  ⚠ macOS $(sw_vers -productVersion): Auracaster braucht macOS 26 oder neuer."

api="https://api.github.com/repos/$REPO/releases/latest"
url="$(curl -fsSL "$api" | /usr/bin/python3 -c 'import json,sys; a=json.load(sys.stdin)["assets"]; print(next(x["browser_download_url"] for x in a if x["name"].endswith(".zip") and "macOS" in x["name"]))')"
tag="$(curl -fsSL "$api" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
echo "  Version: $tag"
echo "  Lade $url"
curl -fL --progress-bar -o "$TMP/Auracaster.zip" "$url"
ditto -x -k "$TMP/Auracaster.zip" "$TMP/x"

if pgrep -xq Auracaster; then echo "  Beende laufendes Auracaster …"; osascript -e 'quit app "Auracaster"' || true; sleep 2; fi
SUDO=""; [ -w "$DEST" ] || SUDO="sudo"
$SUDO rm -rf "$DEST/Auracaster.app"
$SUDO ditto "$TMP/x/Auracaster.app" "$DEST/Auracaster.app"
$SUDO xattr -dr com.apple.quarantine "$DEST/Auracaster.app" 2>/dev/null || true
echo "  ✓ $DEST/Auracaster.app"

if [ "${AURACASTER_SKIP_ENGINE:-0}" != 1 ]; then
  printf '\n\033[1m▶ Funk-Engine einrichten\033[0m (Python + Bumble + LC3, ca. 1–2 Minuten)\n'
  if curl -fsSL "https://raw.githubusercontent.com/$REPO/$tag/engine/setup-engine.sh" -o "$TMP/setup-engine.sh" 2>/dev/null \
     || curl -fsSL "https://raw.githubusercontent.com/$REPO/main/engine/setup-engine.sh" -o "$TMP/setup-engine.sh"; then
    if AURACASTER_ENGINE_REF="$tag" bash "$TMP/setup-engine.sh"; then
      defaults write de.groovex.Auracaster engineKind -string bumble
      defaults write de.groovex.Auracaster transport -string auto
      defaults write de.groovex.Auracaster pythonPath -string "$HOME/Library/Application Support/Auracaster/venv/bin/python"
    else
      echo "  ⚠ Engine-Einrichtung fehlgeschlagen – später in der App unter Einstellungen → Engine einrichten."
    fi
  fi
fi

open "$DEST/Auracaster.app"
printf '\n\033[1m✅ Fertig!\033[0m Auracaster läuft. Der Willkommens-Assistent zeigt die nächsten Schritte.\n\n'
