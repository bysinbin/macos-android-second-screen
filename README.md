# 🖥️ Mac -> Android 2. Ekran (Kablolu & Kablosuz)

Bu proje, USB veya Wi-Fi üzerinden bağlı olan Android telefonunuzu macOS için yüksek performanslı (60 FPS, donanım hızlandırmalı, ultra düşük gecikmeli) **gerçek bir 2. monitör (genişletilmiş ekran / extended display)** veya **Mac ekranı yansıtma (mirror display)** olarak kullanmanızı sağlar.

---

## ✨ Yeni Özellikler (v1.0.3)
- 🖥️ **macOS Masaüstü Uygulaması (`Mac Screen.app`)**: Terminale ihtiyaç duymadan çift tıklamayla çalışan modern macOS grafik arayüzü!
- 🖱️ **Android Mouse / Trackpad Modu**: Doğrudan dokunmatik yerine laptop touchpad'i gibi fare imlecini hareket ettirme, tek parmak tıklama, çift parmak sağ tık ve çift parmakla akıcı kaydırma (scroll).
- 🪞 **Yansıtma (Mirror) & Genişletme (Extend) Seçimi**: Mac ekranını birebir yansıtırken Mac'in Retina çözünürlüğü korunur.

---

## 🏗️ Mimari & Kullanılan Diller

| Bileşen | Teknoloji | Açıklama |
| :--- | :--- | :--- |
| **Mac Uygulaması (GUI)** | **SwiftUI + Swift 6** | `Mac Screen.app`: Arayüzden tek tıkla mod seçimi, USB port bağlama ve canlı yayın başlatma/durdurma. |
| **Mac Sunucu Motoru** | **Swift + Objective-C** | `CGVirtualDisplay` (Sanal monitör oluşturma), `ScreenCaptureKit` (60 FPS GPU ekran yakalama), `VideoToolbox` (H.264 donanımsal sıkıştırma), `Network.framework` (TCP soket & Bonjour). |
| **Android İstemci** | **Kotlin** | `MediaCodec` + `SurfaceView` (Sıfır kopya donanımsal H.264 çözücü), `TouchSender` (Dokunmatik ve Touchpad/Mouse emülasyonu), `BonjourDiscovery` (Wi-Fi otomatik keşif). |
| **Bağlantı** | **TCP / ADB Tüneli** | USB (ADB reverse) üzerinden ~15ms gecikme veya 5 GHz Wi-Fi üzerinden kablosuz. |

---

## 🚀 Başlangıç ve Kullanım

### Seçenek 1: macOS Uygulaması ile (Tavsiye Edilen - Terminal Gerektirmez)
1. Proje dizinindeki **`Mac Screen.app`** uygulamasına çift tıklayarak açın.
2. Modunuzu seçin:
   - 🖥️ **Genişletilmiş 2. Ekran**: Mac masaüstünüze bağımsız ikinci monitör ekler.
   - 🪞 **Mac Ekranını Yansıt**: Mac ekranınızı telefona yansıtır (Mac çözünürlüğünüz düşmez).
3. Telefonunuz USB ile bağlıysa **"🔌 Port Bağla & Başlat"** butonuna basmanız yeterlidir.

### Seçenek 2: Terminalden Tek Komutla Başlatma
```bash
./start.sh
```

---

## 🖱️ Android Dokunmatik & Mouse Modları

Ekranın sağ üst köşesindeki düğmeden veya üst HUD menüsünden iki mod arasında geçiş yapabilirsiniz:
- **📱 Dokunmatik Mod (Doğrudan)**: Telefon ekranında dokunduğunuz yere doğrudan tıklar.
- **🖱️ Mouse / Trackpad Modu**: Laptop touchpad'i gibi çalışır:
  - Tek parmakla kaydırma: Fare imlecini bağıl hareket ettirir.
  - Hızlı tek dokunma: Sol tık.
  - İki parmakla dokunma: Sağ tık.
  - İki parmakla kaydırma: Akıcı sayfa kaydırma (scroll).

---

## 📶 Kablosuz (Wi-Fi) Kullanımı

1. Telefonunuz ve Mac'iniz aynı Wi-Fi ağına bağlı olsun.
2. Mac uygulamasından veya terminalden yayını başlatın.
3. Telefonda:
   * **"📶 Wi-Fi Otomatik Bul"** butonuna basın (Apple Bonjour servisi sayesinde Mac otomatik algılanır).
   * Veya Mac ekranında görünen yerel IP adresini girip **"Bağlan"** butonuna basın.

---

## 📁 Proje Klasör Yapısı

* **`Mac Screen.app`**: Çift tıklanıp çalıştırılabilen macOS uygulaması.
* **`build_app.sh`**: `.app` paketini derleyen otomasyon betiği.
* **`mac/`**: Swift Package projesi (`ScreenCore`, `MacScreenApp`, `MacScreenServer`, `VirtualDisplayBridge`).
* **`android/`**: Gradle Kotlin Android uygulaması (`VideoDecoder`, `TouchSender`, `BonjourDiscovery`, `MainActivity`).
* **`start.sh`**: Terminalden tek tıkla başlatan betik.

---

## 📌 Yapılacaklar (Roadmap)

- [ ] **Touchpad Hız Ayarı**: Android arayüzünde dokunmatik yüzeyin fare hareket hızını ve hassasiyetini (sensitivity slider) ayarlayabilme.
- [ ] **Windows Versiyonu**: Windows işletim sistemi için sanal monitör (IddCx / Direct3D) sürücüsü ve masaüstü sunucu uygulaması.
- [ ] **Armoury Crate & ARGB Entegrasyonu**: Windows sürümünde ASUS Armoury Crate (Aura Sync SDK) ile entegre olarak Android ekranının kenarlarına dinamik senkronize ARGB ışıklandırma ekleme.
