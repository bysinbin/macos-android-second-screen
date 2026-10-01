# 🖥️ Mac -> Android 2. Ekran (Kablolu & Kablosuz)

Bu proje, USB veya Wi-Fi üzerinden bağlı olan Android telefonunuzu macOS için yüksek performanslı (60 FPS, donanım hızlandırmalı, ultra düşük gecikmeli) **gerçek bir 2. monitör (genişletilmiş ekran / extended display)** olarak kullanmanızı sağlar.

---

## 🏗️ Mimari & Kullanılan Diller

| Bileşen | Teknoloji | Açıklama |
| :--- | :--- | :--- |
| **Mac Sunucu** | **Swift + Objective-C** | `CGVirtualDisplay` (Sanal monitör oluşturma), `ScreenCaptureKit` (60 FPS GPU ekran yakalama), `VideoToolbox` (H.264 donanımsal sıkıştırma), `Network.framework` (TCP soket & Bonjour). |
| **Android İstemci** | **Kotlin** | `MediaCodec` + `SurfaceView` (Sıfır kopya donanımsal H.264 çözücü), `TouchSender` (Dokunmatik ekranı fareye çevirme), `BonjourDiscovery` (Wi-Fi otomatik keşif). |
| **Bağlantı** | **TCP / ADB Tüneli** | USB (ADB reverse) üzerinden ~15ms gecikme veya 5 GHz Wi-Fi üzerinden kablosuz. |

---

## 🚀 Hızlı Başlangıç

### 1. Tek Komutla Başlatma (USB Kablosu Takılıyken)
Telefonunuz USB ile Mac'e bağlı ve USB Hata Ayıklama açıkken terminalde şu komutu çalıştırmanız yeterlidir:

```bash
cd /Users/feritetem/Desktop/android-screen
./start.sh
```

Bu script otomatik olarak:
1. `adb reverse tcp:8888 tcp:8888` tünelini açar.
2. Telefonunuzdaki **Mac Screen** uygulamasını otomatik başlatır.
3. Mac sanal ekranını oluşturup 60 FPS yayın yapmaya başlar.
4. Telefonda **"🔌 USB İle Bağlan"** butonuna basarak görüntüyü anında alabilirsiniz.

---

## 📶 Kablosuz (Wi-Fi) Kullanımı

1. Telefonunuz ve Mac'iniz aynı Wi-Fi ağına bağlı olsun.
2. Mac'te `./start.sh` komutunu çalıştırın.
3. Telefonda:
   * **"📶 Wi-Fi Otomatik Bul"** butonuna basın (Apple Bonjour servisi sayesinde Mac otomatik algılanır).
   * Veya Mac terminalinde yazan yerel IP adresini (örn: `192.168.1.35:8888`) girip **"Bağlan"** butonuna basın.

---

## ⚙️ Ekran Modları ve Seçenekler

Sunucuyu farklı çözünürlük veya yönlerde başlatabilirsiniz:

```bash
# Yatay Mod (Varsayılan - 1640x720 Geniş Ekran):
./start.sh --landscape

# Dikey Mod (720x1640 Telefon Oranı):
./start.sh --portrait

# Özel Çözünürlük ve Kare Hızı:
./start.sh --width 1920 --height 1080 --fps 60 --bitrate 8
```

---

## 📱 Dokunmatik Ekran Özelliği

Telefon ekranına dokunduğunuzda, dokunma koordinatları Mac'teki sanal ekrana fare tıklaması ve sürüklemesi olarak yansıtılır. Böylece telefonunuz aynı zamanda dokunmatik bir çizim/kontrol paneli gibi çalışır.

---

## 📁 Proje Klasör Yapısı

* **`mac/`**: Swift Package projesi (`VirtualDisplayBridge` Obj-C köprüsü + `MacScreenServer` Swift motoru).
* **`android/`**: Gradle Kotlin Android uygulaması (`VideoDecoder`, `TouchSender`, `BonjourDiscovery`, `MainActivity`).
* **`start.sh`**: Tek tıkla port tünelini açan, uygulamayı telefonda başlatan ve sunucuyu çalıştıran betik.
