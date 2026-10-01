#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
if [ -f "$DIR/mac/.build/release/MacScreenServer" ]; then
    SERVER_BIN="$DIR/mac/.build/release/MacScreenServer"
else
    SERVER_BIN="$DIR/mac/.build/debug/MacScreenServer"
fi

echo "=================================================="
echo "    🚀 Android 2. Ekran Başlatıcı (Mac + Android) "
echo "=================================================="

# 0. Kill any existing instance running in the background
pkill -9 -f "MacScreenServer" 2>/dev/null || true

# 1. Mode Selection (Yansıtma mı Genişletme mi?)
MODE_ARG=""
EXTRA_ARGS=()

for arg in "$@"; do
    if [[ "$arg" == "--mirror" || "$arg" == "--extend" ]]; then
        MODE_ARG="$arg"
    else
        EXTRA_ARGS+=("$arg")
    fi
done

if [ -z "$MODE_ARG" ]; then
    echo ""
    echo "Bağlantı Modunu Seçin:"
    echo "  1) 🖥️  Genişlet (2. Bağımsız Ekran / Extended Desktop) [Varsayılan]"
    echo "  2) 🪞  Yansıt (Mac Ekranını Yansıt / Mirror - Mac Çözünürlüğü Korunur)"
    echo ""
    read -t 8 -p "Seçiminiz [1 veya 2, 8sn sonra otomatik 1]: " USER_CHOICE || USER_CHOICE="1"
    echo ""
    if [ "$USER_CHOICE" = "2" ]; then
        MODE_ARG="--mirror"
        echo "👉 Mod: Yansıtma (Mirror) seçildi."
    else
        MODE_ARG="--extend"
        echo "👉 Mod: Genişletilmiş 2. Ekran seçildi."
    fi
fi

# 2. Check if ADB device is connected
if [ -f "$ADB" ]; then
    DEVICE_COUNT=$("$ADB" devices | grep -v "List" | grep "device" | wc -l | tr -d ' ')
    if [ "$DEVICE_COUNT" -gt "0" ]; then
        echo "🔌 Android cihazı USB üzerinden algılandı."
        echo "   -> Port yönlendirme ayarlanıyor: adb reverse tcp:8888 tcp:8888"
        "$ADB" reverse tcp:8888 tcp:8888
        
        echo "   -> Uygulama telefonda başlatılıyor..."
        "$ADB" shell am start -n com.antigravity.androidscreen/.MainActivity >/dev/null 2>&1 || true
    else
        echo "ℹ️  USB ile bağlı cihaz bulunamadı. Kablosuz (Wi-Fi) modda bağlanabilirsiniz."
    fi
fi

echo ""
echo "🖥️  Mac ekran sunucusu başlatılıyor..."
echo "   (Durdurmak için Ctrl+C'ye basın)"
echo "--------------------------------------------------"
exec "$SERVER_BIN" "$MODE_ARG" "${EXTRA_ARGS[@]}"
