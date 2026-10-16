#!/bin/bash
set -e

# --- Interaktywne menu wyboru języka (strzałki Góra/Dół + Enter) ---
choose_language() {
    local selected=0
    local key=""
    
    # Ukrycie kursora
    tput civis 2>/dev/null || true

    while true; do
        clear
        echo "=============================================================="
        echo " Nuvio macOS 10.13 High Sierra Compatibility Patch Backport   "
        echo "=============================================================="
        echo ""
        echo " Select language / Wybierz jezyk (Use arrows / Uzyj strzalek):"
        echo ""
        if [ $selected -eq 0 ]; then
            echo "  > [ Polski ]  "
            echo "      English   "
        else
            echo "      Polski    "
            echo "  > [ English ] "
        fi
        echo ""
        echo "=============================================================="

        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            if [[ $key == "[A" || $key == "[B" ]]; then
                selected=$((1 - selected))
            fi
        elif [[ $key == "" ]]; then
            break
        fi
    done

    # Przywrócenie kursora
    tput cnorm 2>/dev/null || true
    clear

    if [ $selected -eq 0 ]; then
        LANG_CHOICE="PL"
    else
        LANG_CHOICE="EN"
    fi
}

choose_language

# --- Słownik komunikatów ---
if [ "$LANG_CHOICE" = "PL" ]; then
    MSG_ERR_NO_APP="[BLAD] Nie znaleziono aplikacji w /Applications/Nuvio.app"
    MSG_ERR_INSTALL="Zainstaluj najpierw Nuvio.app w folderze /Applications."
    MSG_STEP1="[1/4] Tworzenie katalogu Legacy i kopiowanie kodu zrodlowego..."
    MSG_STEP2="[2/4] Kompilacja biblioteki legacy_shim.dylib (-O3)..."
    MSG_STEP3="[3/4] Patchowanie bibliotek natywnych Mach-O pod dyld z macOS 10.13..."
    MSG_PY_UPD="  -> Zaktualizowano symbole w:"
    MSG_STEP4="[4/4] Instalacja zoptymalizowanego launchera i czyszczenie cache UI..."
    MSG_DONE=" GOTOWE. Nuvio jest gotowe do pracy na macOS 10.13 High Sierra"
else
    MSG_ERR_NO_APP="[ERROR] Application not found in /Applications/Nuvio.app"
    MSG_ERR_INSTALL="Please install Nuvio.app in the /Applications folder first."
    MSG_STEP1="[1/4] Creating Legacy directory and copying source code..."
    MSG_STEP2="[2/4] Compiling legacy_shim.dylib library (-O3)..."
    MSG_STEP3="[3/4] Patching Mach-O native libraries for macOS 10.13 dyld..."
    MSG_PY_UPD="  -> Updated symbols in:"
    MSG_STEP4="[4/4] Installing optimized launcher and clearing UI cache..."
    MSG_DONE=" DONE. Nuvio is ready to run on macOS 10.13 High Sierra"
fi

APP_PATH="/Applications/Nuvio.app"
CONTENTS="$APP_PATH/Contents"
LEGACY_DIR="$CONTENTS/Legacy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=============================================================="
echo " Nuvio macOS 10.13 High Sierra Compatibility Patch Backport   "
echo "=============================================================="

if [ ! -d "$APP_PATH" ]; then
    echo "$MSG_ERR_NO_APP"
    echo "$MSG_ERR_INSTALL"
    exit 1
fi

echo "$MSG_STEP1"
mkdir -p "$LEGACY_DIR"
cp "$SCRIPT_DIR/legacy_shim.m" "$LEGACY_DIR/legacy_shim.m"

echo "$MSG_STEP2"
clang -O3 -dynamiclib "$LEGACY_DIR/legacy_shim.m" \
  -o "$LEGACY_DIR/legacy_shim.dylib" \
  -framework Foundation -framework AppKit -framework WebKit -framework CoreText -framework CoreGraphics \
  -lexpat -Wl,-U,_objc_msgSend -current_version 80.0.0 -compatibility_version 1.0.0

echo "$MSG_STEP3"
export MSG_PY_UPD
python - << 'PYEOF'
import os, glob

app = "/Applications/Nuvio.app/Contents"
msg_upd = os.environ.get("MSG_PY_UPD", "  -> Updated:")
dylibs = (
    glob.glob(os.path.join(app, "app/*.dylib")) +
    glob.glob(os.path.join(app, "app/resources/native/macos/*.dylib")) +
    glob.glob(os.path.join(app, "runtime/Contents/Home/lib/*.dylib")) +
    glob.glob(os.path.join(app, "runtime/Contents/Home/lib/server/*.dylib"))
)

replacements = [
    (b"__objc_catlist\x00", b"__objc_catlisX\x00"),
    (b"_mpv_create\x00", b"_mpv_creatX\x00"),
    (b"_mpv_set_option_string\x00", b"_mpv_set_option_strinX\x00"),
    (b"_mpv_command\x00", b"_mpv_commanX\x00"),
    (b"_mpv_render_context_free\x00", b"_mpv_render_context_freX\x00"),
    (b"_mpv_terminate_destroy\x00", b"_mpv_terminate_destroX\x00"),
]

for path in dylibs:
    if not os.path.isfile(path) or os.path.islink(path):
        continue
    with open(path, "rb") as f:
        data = f.read()
    orig = data

    if "libplayer_bridge.dylib" in path:
        for old, new in replacements:
            data = data.replace(old, new)
    else:
        data = data.replace(b"__objc_catlist\x00", b"__objc_catlisX\x00")

    if data != orig:
        with open(path, "wb") as f:
            f.write(data)
        print(msg_upd, os.path.basename(path))
PYEOF

echo "$MSG_STEP4"
cat << 'LAUNCHEOF' > "$CONTENTS/MacOS/Nuvio"
#!/bin/bash
DIR="/Applications/Nuvio.app/Contents"
export DYLD_FALLBACK_LIBRARY_PATH="$DIR/app/resources/native/macos:/usr/lib"
export DYLD_FALLBACK_FRAMEWORK_PATH="/System/Library/Frameworks/JavaVM.framework/Versions/A/Frameworks"
export DYLD_FORCE_FLAT_NAMESPACE=1
export DYLD_INSERT_LIBRARIES="$DIR/Legacy/legacy_shim.dylib"

exec "$DIR/runtime/Contents/Home/bin/java" \
  -Xms512m \
  -Xmx1536m \
  -Djpackage.app-version=1.1.30 \
  -Dcompose.application.resources.dir="$DIR/app/resources" \
  -Dcompose.application.configure.swing.globals=true \
  -Dapple.awt.application.appearance=NSAppearanceNameDarkAqua \
  -Djdk.gtk.version=0 \
  --add-opens=java.desktop/java.awt=ALL-UNNAMED \
  --add-opens=java.desktop/sun.lwawt=ALL-UNNAMED \
  --add-opens=java.desktop/sun.lwawt.macosx=ALL-UNNAMED \
  -Dskiko.library.path="$DIR/app" \
  -Xdock:name=Nuvio \
  -Xdock:icon="$DIR/Resources/Nuvio.icns" \
  -cp "$DIR/app/*" \
  com.nuvio.app.MainKt
LAUNCHEOF

chmod +x "$CONTENTS/MacOS/Nuvio"
rm -rf "$HOME/Library/Caches/Nuvio/player-ui" /tmp/nuvio_sub_*.srt /tmp/mpv_nuvio.log

echo "=============================================================="
echo "$MSG_DONE"
echo "=============================================================="