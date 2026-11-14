# PalmMap iOS 3.8.9 (462)

Bu SwiftUI projesi, Android 3.8.9 (462) yayın kaynağından hazırlanmış ilk iPhone portudur. Minimum cihaz sürümü iOS 17’dir. App Store Connect’e gönderilecek derleme için Xcode 26 ve iOS 26 SDK veya daha yeni bir sürüm kullanılır.

## Projeyi aç

Windows üzerinden derlemek için [BASLA_WINDOWS_TR.md](BASLA_WINDOWS_TR.md) dosyasındaki GitHub Actions adımlarını izle.

1. Mac’te **PalmMap.xcodeproj** dosyasını aç ve **PalmMap** şemasını seç. Xcode, Firebase, Google Sign-In, ONNX Runtime, Google Mobile Ads ve UMP paketlerini çözer.
2. Apple Developer hesabında Bundle ID’yi oluştur. Başlangıç değeri **com.palmmap.app**. Bu değer değişirse Xcode, Firebase ve Cloud Run’daki iOS yapılandırmasını birlikte güncelle. App ID için **Sign in with Apple** ve **App Attest** yeteneklerini etkinleştir.
3. **Config/Local.xcconfig.example** dosyasını aynı dizinde **Local.xcconfig** olarak kopyala. Team ID ve Bundle ID’yi gir. Firebase’de aynı Bundle ID ile Apple uygulaması ekle ve indirilen **GoogleService-Info.plist** ile **Config/GoogleService-Info.plist** dosyasını değiştir.
4. Firebase Authentication’da Apple ve Google sağlayıcılarını etkinleştir. Apple sağlayıcısına OAuth yapılandırmasını da gir. Bu yapılandırma Apple ile açılan hesabı silerken giriş yetkisini iptal etmek için kullanılır. iOS Firebase plist’indeki **REVERSED_CLIENT_ID** değerini Local.xcconfig içindeki **PALMMAP_GOOGLE_REVERSED_CLIENT_ID** alanına yaz. Firebase App Check’te iOS uygulamasına App Attest kaydet. Geliştirme simülatöründe Firebase App Check debug sağlayıcısı kullanılır.
5. Simülatörde fotoğraf seçimiyle akışı, gerçek iPhone’da kamera ve App Attest’i dene. Kaynak paketteki örnek Firebase plist’i ile cihaz içi ön izleme açılabilir. Giriş, sunucu ve mağaza işlevleri gerçek yapılandırmayı kullanır.

## App Store Connect ve Cloud Run

| Ürün kimliği | Apple ürün türü | İçerik |
| --- | --- | --- |
| elharitasi_deep_report | Consumable | Bir kişisel okuma |
| elharitasi_partner_analysis | Consumable | Bir ilişki analizi |
| elharitasi_plus | Auto-Renewable Subscription | Bir aylık dönem, 30 analiz hakkı |

Fiyatları ve yerelleştirilmiş ürün adlarını App Store Connect’te gir. Ekran fiyatı StoreKit’ten alır. Aylık Plus ürünü için bir abonelik grubu oluştur ve Family Sharing ayarını kapalı bırak. Ürünler ilk uygulama sürümüyle incelemeye gönderilebilir.

**Gateway/**, PalmMap 3.8.7 (460) Cloud Run kaynak arşivindeki gateway üzerine hazırlanmıştır. Canlı gateway farklı bir revizyondaysa değişiklikleri önce onun kaynağına birleştir. Android satın alma doğrulaması ve mevcut AI worker uçları bu gateway içinde kullanılır. Apple JWS doğrulaması, Apple’ın App Store Server Library paketiyle yapılır.

- Apple PKI sayfasından resmi DER kök sertifikalarını al. Bunları Cloud Run kapsayıcısında salt okunur bir dizine **.cer** uzantısıyla bağla. **PALMMAP_APPLE_ROOT_CERTS_DIR** bu dizinin yoludur. Apple’ın doğrulama kitaplığının sertifika durumunu kontrol edebilmesi için Cloud Run çıkışı çalışmalıdır.
- **PALMMAP_APPLE_APP_ID** alanına App Store Connect’in sayısal Apple ID değerini, **PALMMAP_APPLE_BUNDLE_ID** alanına iOS Bundle ID’yi gir. Hazır ortamda **PALMMAP_APPLE_STORE_ENABLED=true** ayarını etkinleştir. Apple App Store Server Notifications V2 adresi **https://<gateway>/apple/notifications**.
- Sandbox/TestFlight doğrulaması için **PALMMAP_APPLE_SANDBOX_UIDS** alanına özel test ve inceleme hesaplarının Firebase UID’lerini virgülle ayırarak yaz. Sandbox işlemleri bu hesaplarla sınırlıdır. Yayın öncesinde gerçek kullanıcı hesaplarından ayrı test hesaplarıyla dene. TestFlight alımları sandbox’ta çalışır.
- AdMob’da ayrı bir **iOS uygulaması** ve **iOS Rewarded** reklam birimi oluştur. **PALMMAP_ADMOB_APP_ID** ve **PALMMAP_ADMOB_REWARDED_ID** değerlerini Local.xcconfig’e gir. Sunucuda **PALMMAP_IOS_REWARDED_AD_UNIT** ve **PALMMAP_IOS_FIREBASE_APP_ID** değerlerini eşleştir. AdMob SSV URL’si **https://<gateway>/admob/ssv**. UMP mesajını iOS uygulamasına da tanımla. Altın, SDK’nın uygun USD gelir bildirimi ve Google imzalı SSV doğrulaması birlikte ulaştığında hesaplanır. Türkiye App Store bölgesinde reklam istemi devre dışıdır.
- Gizlilik politikası adresi gateway’in **/privacy** sayfasıdır. App Privacy yanıtlarını gerçek Firebase, OpenAI ve AdMob veri akışına göre doldur. Kamera yalnızca cihaz içi analiz için kullanılır. Kişisel raporda yaş, işlenmiş el bulguları ve seçilmiş sembolik yıllar, izin ekranı geçildikten sonra PalmMap sunucusu üzerinden OpenAI’ye gider. Fotoğraflar, isimler ve tam tarihler cihazda işlenir.
- App Review notlarında cihaz içi avuç çizgisi segmentasyonunu, iki kişiden ölçülen bulgularla oluşturulan ilişki raporunu ve rapor için erişim adımlarını açıkla. Gerekli hakları içeren inceleme hesabını veya inceleyicinin tüm özelliklere ulaşabileceği yöntemi App Review bilgilerine ekle. App Store ekran görüntülerini gerçek iOS derlemesinden al.

## Doğrulama ve kapsam

- Bu paket Xcode projesini, Swift kaynaklarını, Android’deki ana çizgi ONNX modelini, TR/EN profil ve ilişki verilerini ve Cloud Run gateway kodunu içerir.
- iOS sürümü Apple Vision ile avuç konumunu bulur ve Android’de kullanılan Kalp, Akıl ve Hayat çizgisi modelini çalıştırır. Bu port iki avuç içiyle ilerler. Android’le tam özellik eşitliği için el sırtı çekimi, Kader/Güneş ve yardımcı çizgi motorları, tam çizgi iyileştirme zinciri ve hatırlatmalar açık kalıyor. İlişki raporundaki mühür açma etkileşimi ve raporun PDF paylaşımı iOS’ta yeniden uygulandı.
- Raporlar cihazda hesap bazında saklanır. Son kişisel rapor mevcut Cloud Run API üzerinden geri getirilebilir. İlişki arşivi cihazda saklanır.
- Kodda uygulanan kontrollerin yanında gerçek iPhone’da fotoğraf yönü, farklı ten tonları ve aydınlatmalar, iki avuçta çizgi yerleşimi, Türkçe/İngilizce, Apple/Google girişi, satın alma, iade, Plus yenileme, geri yükleme, hesap silme ve SSV akışlarını doğrula.
- Proje dosyaları, Swift sözdizimi, paket sürümleri ve ONNX modelinin CPU çıkarımı kontrol edildi. Mevcut 45 gateway testi ve yeni 10 Apple ödeme testi geçti. Xcode derlemesi, gerçek iPhone testi, canlı Cloud Run dağıtımı, TestFlight ve App Store gönderimi sıradaki doğrulama adımlarıdır.

Resmi kaynaklar

- [App Store inceleme kuralları](https://developer.apple.com/app-store/review/guidelines/)
- [Apple SDK gereksinimleri](https://developer.apple.com/news/upcoming-requirements/)
- [Apple PKI](https://www.apple.com/certificateauthority/)
- [Firebase iOS Apple girişi](https://firebase.google.com/docs/auth/ios/apple)
- [Firebase App Attest](https://firebase.google.com/docs/app-check/ios/app-attest-provider)
- [AdMob iOS ödüllü reklamlar](https://developers.google.com/admob/ios/rewarded)
