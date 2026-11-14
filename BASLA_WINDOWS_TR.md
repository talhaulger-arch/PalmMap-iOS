# PalmMap’i Windows’tan derle

GitHub Actions, iPhone simülatörü için PalmMap’i Xcode ile derler. Derlemeyi Windows’ta tarayıcıdan başlatır ve sonucunu GitHub’da görürsün.

## 1. Kaynak kodu yükle

1. ZIP’i ayıkla ve içindeki **PalmMap_iOS_3.8.9_462** klasörünü aç.
2. [GitHub’da yeni depo aç](https://github.com/new). Depo adı olarak **PalmMap-iOS** yaz, **Private** seç ve **Add README** seçeneğini aç. Ardından **Create repository** düğmesine bas.
3. Depoda **Code → Add file → Upload files** yolunu aç. Windows Dosya Gezgini’nden iç klasördeki bütün dosya ve klasörleri tarayıcıya sürükle. GitHub’daki **Code** ekranında **.github**, **PalmMap.xcodeproj**, **PalmMap**, **Config** ve **Gateway** yan yana görünmeli. **Commit changes** ile varsayılan dala kaydet.

## 2. İlk Xcode derlemesini başlat

1. GitHub’da **Actions → PalmMap iOS Derleme → Run workflow** yolunu aç. Açılan menüde varsayılan dalı seç ve **Run workflow** düğmesine bas.
2. Çalıştırmayı aç. Yeşil sonuç Xcode derlemesinin tamamlandığını gösterir. Kırmızı sonuçta çalıştırmanın **Summary → Artifacts** alanından **PalmMap-iOS-Derleme-Logu** dosyasını indir. İlk hata satırları **Xcode ile derle** adımında da görünür.

İlk işlem iPhone simülatörünü hedefler ve uygulama kodunu derleme açısından kontrol eder. Telefona kurulum ve satın alma, giriş ve reklam testi için sıradaki adım Apple Developer hesabıyla imzalanmış bir **TestFlight** derlemesidir. PalmMap’in iOS Firebase ve mağaza ayarları [BASLA_TR.md](BASLA_TR.md) dosyasında.
