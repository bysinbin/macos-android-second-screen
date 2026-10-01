#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
SERVER_BIN="$DIR/mac/.build/debug/MacScreenServer"

echo "=================================================="
echo "    🚀 Android 2. Ekran Başlatıcı (Mac + Android) "
echo "=================================================="

# 1. Check if server binary exists, build if not
if [ ! -f "$SERVER_BIN" ]; then
    echo "📦 MacScreenServer derleniyor..."
    (cd "$DIR/mac" && swift build)
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
echo "🖥️  Mac sanal ekran sunucusu başlatılıyor..."
echo "   (Durdurmak için Ctrl+C'ye basın)"
echo "--------------------------------------------------"
exec "$SERVER_BIN" "$@"
