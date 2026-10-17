#!/bin/bash
# Auracaster – Engine einrichten (Python + Bumble + LC3), ohne Xcode, ohne Homebrew.
#
# Legt ~/Library/Application Support/Auracaster/venv an (Python 3.12 über "uv" von Astral,
# das bei Bedarf nach ~/.local/bin geladen wird) und installiert Bumble aus dem Auracaster-Repo
# samt LC3-Encoder (lc3py). Wird von der App (Willkommen → Engine einrichten), vom
# Terminal-Installer und von Hand benutzt:
#
#   bash setup-engine.sh            # Ref = main
#   AURACASTER_ENGINE_REF=v0.1.1 bash setup-engine.sh
#
# Am Ende steht eine Zeile "AURACASTER_PYTHON=<pfad>", die die App ausliest.
# "$BASE/engine-version" enthält danach den installierten Ref; die App richtet die
# Engine automatisch neu ein, wenn er nicht zur App-Version passt (Update).
set -euo pipefail

REPO="thegroovex/Auracaster"
REF="${AURACASTER_ENGINE_REF:-main}"
BASE="${AURACASTER_HOME:-$HOME/Library/Application Support/Auracaster}"
VENV="$BASE/venv"
PY_VERSION="${AURACASTER_PYTHON_VERSION:-3.12}"

step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

step "Auracaster-Engine wird eingerichtet (Ziel: $VENV)"
mkdir -p "$BASE"

if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" != "arm64" ]; then
  echo "  ⚠ Intel-Mac erkannt: für lc3py gibt es nur Pakete für Apple-Chips (arm64)."
  echo "    Die Installation wird versucht, der LC3-Encoder fehlt aber wahrscheinlich."
fi

# 1. uv (lädt Python selbst, braucht keine Entwicklerwerkzeuge)
UV="$(command -v uv 2>/dev/null || true)"
[ -z "$UV" ] && [ -x "$HOME/.local/bin/uv" ] && UV="$HOME/.local/bin/uv"
if [ -z "$UV" ]; then
  step "Lade uv (Python-Paketmanager von Astral) nach ~/.local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null
  UV="$HOME/.local/bin/uv"
fi
ok "uv: $("$UV" --version)"

# 2. Python + venv
step "Python $PY_VERSION und virtuelle Umgebung"
"$UV" venv --quiet --allow-existing --python "$PY_VERSION" "$VENV"
ok "$("$VENV/bin/python" --version)"

# 3. Bumble aus dem Auracaster-Repo (Tarball, kein git nötig)
URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
case "$REF" in v[0-9]*) URL="https://github.com/$REPO/archive/refs/tags/$REF.tar.gz";; esac
if ! curl -fsIL "$URL" >/dev/null 2>&1; then
  echo "  ⚠ $REF nicht gefunden – nehme main"
  URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
fi
step "Installiere Bumble + LC3 aus $URL"
# Ohne .git kennt setuptools_scm keine Version – feste Version vorgeben.
# --reinstall-package: the version string is always the same, so without it an
# update would keep the old (v0.1.0: incomplete) bumble package in the venv.
SETUPTOOLS_SCM_PRETEND_VERSION="0.0.0+auracaster" \
  "$UV" pip install --quiet --reinstall-package bumble --python "$VENV/bin/python" "bumble[auracast] @ $URL"
ok "Pakete installiert"

# 4. Selbsttest: jedes Bumble-Unterpaket + LC3 muss importierbar sein
step "Selbsttest"
"$VENV/bin/python" - <<'PY'
import importlib, pathlib, pkgutil, sys
import bumble
failures = []
base = pathlib.Path(bumble.__file__).parent
for info in pkgutil.walk_packages([str(base)], "bumble."):
    if info.ispkg:
        try:
            importlib.import_module(info.name)
        except ImportError as error:
            if "grpc" not in str(error) and "protobuf" not in str(error):
                failures.append(f"{info.name}: {error}")
for name in ("bumble.device", "bumble.crypto", "bumble.profiles.bap", "bumble.audio.io"):
    try:
        importlib.import_module(name)
    except ImportError as error:
        failures.append(f"{name}: {error}")
print("  ✓ bumble", getattr(bumble, "__version__", "?"), "aus", base)
try:
    import lc3  # noqa: F401
    print("  ✓ lc3 (LC3-Encoder)")
except ImportError:
    failures.append("lc3 (LC3-Encoder) fehlt – Senden ist so nicht möglich")
for line in failures:
    print("  ✗", line)
sys.exit(1 if failures else 0)
PY
echo "$REF" > "$BASE/engine-version"
ok "Engine-Version $REF"

printf '\n✅ Fertig. Die Engine liegt in %s\n' "$VENV"
echo "AURACASTER_PYTHON=$VENV/bin/python"
