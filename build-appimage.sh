#!/usr/bin/env bash
# Build an Odysseus AppImage with embedded update information for Gear Lever /
# AppImageUpdate.
#
#   ./build-appimage.sh [ODYSSEUS_SRC_DIR] [OUTPUT_DIR]
#
# Environment:
#   UPDATE_REPO   GitHub "owner/repo" whose releases carry the AppImage
#                 (default: $GITHUB_REPOSITORY, set automatically in Actions).
#                 Without it the AppImage is built without update info.
#   PYTHON_VERSION  bundled Python (default 3.12)
#   ODYSSEUS_REPO   upstream git URL, used when ODYSSEUS_SRC_DIR is missing
#   ODYSSEUS_REF    upstream branch/tag to clone (default: main)
#
# Requires: git, uv, curl, file. appimagetool is downloaded if not on PATH.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$SELF_DIR/build/odysseus}"
OUT="${2:-$SELF_DIR/dist}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
ODYSSEUS_REPO="${ODYSSEUS_REPO:-https://github.com/odysseus-dev/odysseus.git}"
ODYSSEUS_REF="${ODYSSEUS_REF:-main}"
UPDATE_REPO="${UPDATE_REPO:-${GITHUB_REPOSITORY:-}}"
ARCH="$(uname -m)"
WORK="$SELF_DIR/build"
APPDIR="$WORK/AppDir"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

mkdir -p "$WORK" "$OUT"

# --- 1. Source -------------------------------------------------------------
if [[ ! -f "$SRC/app.py" ]]; then
  log "Cloning $ODYSSEUS_REPO ($ODYSSEUS_REF)"
  rm -rf "$SRC"
  git clone --depth 1 --branch "$ODYSSEUS_REF" "$ODYSSEUS_REPO" "$SRC"
fi
COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
VERSION="$(tr -d '[:space:]' < "$SRC/HARNESS_VERSION" 2>/dev/null || echo 0.0.0)"
SHORT="${COMMIT:0:7}"
log "Odysseus $VERSION ($SHORT)"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/share" "$APPDIR/usr/bin"

# --- 2. Relocatable Python (python-build-standalone via uv) ----------------
log "Bundling Python $PYTHON_VERSION"
export UV_PYTHON_INSTALL_DIR="$WORK/pythons"
uv python install "$PYTHON_VERSION"
PY_SRC="$(dirname "$(dirname "$(readlink -f "$(uv python find --managed-python "$PYTHON_VERSION")")")")"
cp -a "$PY_SRC" "$APPDIR/usr/python"
PY="$APPDIR/usr/python/bin/python3"
rm -f "$APPDIR"/usr/python/lib/python3*/EXTERNALLY-MANAGED

# --- 3. Python dependencies -------------------------------------------------
log "Installing requirements"
# pytest/httpx2 are test-only; the rest is installed exactly as upstream lists.
grep -vE '^\s*(pytest|pytest-asyncio|httpx2)\s*$' "$SRC/requirements.txt" > "$WORK/requirements.txt"
uv pip install --python "$PY" --break-system-packages --no-cache \
  --python-platform "${ARCH}-manylinux_2_28" -r "$WORK/requirements.txt"

# --- 4. Application files ---------------------------------------------------
log "Copying application"
APPROOT="$APPDIR/usr/share/odysseus"
mkdir -p "$APPROOT"
tar -C "$SRC" \
  --exclude=.git --exclude=.github --exclude=tests --exclude=docs --exclude=website \
  --exclude=swift --exclude=docker --exclude='docker-compose*.yml' --exclude=Dockerfile \
  --exclude=venv --exclude=.venv --exclude=node_modules --exclude=data --exclude=logs \
  --exclude=.env --exclude='__pycache__' --exclude='*.pyc' \
  -cf - . | tar -C "$APPROOT" -xf -
echo "$COMMIT" > "$APPROOT/SOURCE_COMMIT"
install -m 0644 "$SELF_DIR/packaging/odysseus-launcher.py" "$APPDIR/usr/share/odysseus-launcher.py"

# Precompile everything so nothing tries to write .pyc into the read-only image.
log "Precompiling bytecode"
"$PY" -m compileall -q -j0 "$APPROOT" "$APPDIR/usr/share/odysseus-launcher.py" "$APPDIR/usr/python/lib" >/dev/null || true
# Strip caches/tests that only bloat the image.
rm -rf "$APPDIR"/usr/python/lib/python3*/test "$APPDIR"/usr/python/lib/python3*/idlelib "$APPDIR"/usr/python/lib/python3*/tkinter/test

# --- 5. AppImage metadata ---------------------------------------------------
log "Writing AppRun, desktop file and icon"
install -m 0755 "$SELF_DIR/packaging/AppRun" "$APPDIR/AppRun"
ICON_SRC="$SRC/static/icons/icon-512.png"
install -m 0644 "$ICON_SRC" "$APPDIR/odysseus.png"
mkdir -p "$APPDIR/usr/share/icons/hicolor/512x512/apps"
install -m 0644 "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/512x512/apps/odysseus.png"
ln -sf odysseus.png "$APPDIR/.DirIcon"

cat > "$APPDIR/odysseus.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Odysseus
GenericName=AI Workspace
Comment=Self-hosted AI workspace (opens in your browser)
Exec=odysseus %U
Icon=odysseus
Terminal=false
Categories=Network;Utility;
StartupNotify=false
Keywords=AI;LLM;chat;assistant;
X-AppImage-Version=$VERSION-$SHORT
Actions=Stop;

[Desktop Action Stop]
Name=Stop Odysseus
Exec=odysseus --stop
EOF
mkdir -p "$APPDIR/usr/share/applications"
cp "$APPDIR/odysseus.desktop" "$APPDIR/usr/share/applications/"

# --- 6. Pack ----------------------------------------------------------------
APPIMAGETOOL="$(command -v appimagetool || true)"
if [[ -z "$APPIMAGETOOL" ]]; then
  APPIMAGETOOL="$WORK/appimagetool"
  if [[ ! -x "$APPIMAGETOOL" ]]; then
    log "Downloading appimagetool"
    curl -fsSL -o "$APPIMAGETOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
    chmod +x "$APPIMAGETOOL"
  fi
fi

FILE="Odysseus-${VERSION}-${SHORT}-${ARCH}.AppImage"
ARGS=()
if [[ -n "$UPDATE_REPO" ]]; then
  UPDATE_INFO="gh-releases-zsync|${UPDATE_REPO%%/*}|${UPDATE_REPO##*/}|latest|Odysseus-*-${ARCH}.AppImage.zsync"
  log "Embedding update info: $UPDATE_INFO"
  ARGS+=(-u "$UPDATE_INFO")
else
  log "UPDATE_REPO not set: building without update info"
fi

log "Packing $FILE"
rm -f "$OUT/$FILE" "$OUT/$FILE.zsync"
# APPIMAGE_EXTRACT_AND_RUN lets appimagetool run without FUSE (CI/containers).
( cd "$OUT" && APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" VERSION="$VERSION-$SHORT" \
    "$APPIMAGETOOL" --no-appstream "${ARGS[@]}" "$APPDIR" "$FILE" )

ls -lh "$OUT"
# Expose outputs to GitHub Actions.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "file=$OUT/$FILE"
    echo "zsync=$OUT/$FILE.zsync"
    echo "version=$VERSION"
    echo "commit=$COMMIT"
    echo "tag=v$VERSION-$SHORT"
  } >> "$GITHUB_OUTPUT"
fi
