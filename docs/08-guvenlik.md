# 08 · Güvenlik

Bu bölüm sistemin nerede korunduğunu ve prototipte **bilerek** açık bırakılan noktaları listeler. Bitirme raporunda "kısıtlar" bölümüne aynen aktarılabilir.

## 1. Katman katman

| Katman | Koruma (v1) | Açık nokta | Plan |
|---|---|---|---|
| Radyo (LoRa) | CRC ile bozuk paket reddi, SEQ ile tekrar ayıklama | **Şifreleme ve kimlik doğrulama yok.** Aynı frekanstaki biri paketleri okuyabilir ve sahte COMMAND gönderebilir | v2: AES-128-CCM + 4 baytlık MIC, düğüm başına anahtar (çerçeve ≤ 58 bayt) |
| Saha cihazı (Modbus RTU) | Sadece haritadaki register'lar okunur/yazılır; cihaz devre dışıyken (`CIHAZ_ETKIN` 0) vana komutu reddedilir | Modbus'ta kimlik doğrulama yok; RS-485 hattına fiziksel erişen biri cihaza yazabilir | Hat kutu içinde kalır; sahadaki mevcut güvenlik önlemlerine tabidir |
| Gateway ↔ Supabase | HTTPS, **TLS sertifikası doğrulanır**: `root_ca.h` içindeki ISRG Root X1/X2 ve GTS Root R1/R4 kökleri `setCACert` ile kullanılır, `setInsecure` yok. TLS'ten önce NTP ile saat ayarlanır. Gateway'e özel kullanıcı (`app_metadata.role = gateway`), kısa ömürlü JWT, süresi dolmadan yenileme | Supabase'in sertifika zinciri başka bir köke geçerse gateway bağlanamaz (güvenli tarafta hata) | Yeni kökün PEM'i `root_ca.h`'ye eklenir (`firmware/README.md` (`lora-water-hardware` → `firmware/README.md`)) |
| Veritabanı | Row Level Security her tabloda açık. Telemetriyi ve komut durumunu sadece gateway yazar; komutu sadece **operatör ve yönetici** ekler (`pending` ile); rolleri ve eşikleri sadece **yönetici** değiştirir; durum sütunlarını sadece gateway değiştirir; son yönetici düşürülemez; `alerts` sadece veritabanı fonksiyonlarıyla yazılır; `anon` hiçbir şey göremez | Giriş yapmış her kullanıcı tüm cihazları görür | v2: kullanıcı–cihaz yetki tablosu |
| Mobil uygulama | Supabase Auth, oturum cihazda saklanır; rol arayüzde de uygulanır (izleyici komut butonu görmez) ama asıl kural RLS'dedir | Kayıt ekranı yok (kullanıcıları yönetici ekler) | Bilinçli tercih |
| Push bildirimi | `push_tokens` satırlarını herkes sadece kendisi için okur/yazar/siler; kayıt `register_push_token()` ile; çıkışta token silinir. Edge Function `x-webhook-secret` başlığını `WEBHOOK_SECRET` ile karşılaştırır, `DeviceNotRegistered` token'larını siler | Bildirim metni (cihaz adı + alarm mesajı) Expo ve Google/Apple push servislerinden geçer | Mesajda hassas bilgi yok |
| Gizli bilgiler | Gateway: `firmware/include/secrets.h` (Wi-Fi, Supabase URL, `anon` anahtar, gateway kullanıcısı) `.gitignore`'da; repoda sadece `secrets.example.h`. Mobil: `.env.local` Git'e girmez, EAS'te sadece herkese açık `EXPO_PUBLIC_*` değerleri. Edge Function: `WEBHOOK_SECRET` (ve isteğe bağlı `EXPO_ACCESS_TOKEN`) Supabase secrets'ta. Uç düğüm firmware'inde gizli bilgi yok | Gateway kullanıcısının şifresi ESP32 flash'ında düz metin | Kabul edilebilir (karta fiziksel erişim gerekir); gateway kullanıcısı komut ekleyemez, rolü sınırlıdır |

## 2. Kurallar

1. `service_role` / secret anahtar **hiçbir zaman** gateway'e, firmware'e, uygulamaya, EAS ortam değişkenlerine veya repoya girmez. Tek kullanıldığı yer Edge Function ortamıdır ve orada Supabase tarafından otomatik verilir (`SUPABASE_SERVICE_ROLE_KEY`).
2. Gateway sadece `anon` / publishable anahtar ve kendi kullanıcısıyla çalışır.
3. `firmware/include/secrets.h` ve `mobile/.env.local` commit edilmez. Yanlışlıkla commit edilirse anahtar Supabase panelinden, gateway kullanıcısının şifresi ve Wi-Fi şifresi **hemen yenilenir**; dosyayı silmek yetmez, Git geçmişinde kalır.
4. `WEBHOOK_SECRET` mutlaka ayarlanır: fonksiyon `--no-verify-jwt` ile yayınlandığı için bu değer yoksa herkes çağırabilir. Uzun ve rastgele seçilir, webhook başlığındaki değerle aynı olmalıdır; değiştirilirse ikisi birlikte güncellenir.
5. İlk yönetici sadece SQL Editor'den atanır; uygulamada kendi kendine yönetici olma yolu yoktur.
6. Yeni tablo eklenirse RLS açılır ve `backend/supabase/tests` altındaki test dosyalarına test eklenir.

## 3. Komut güvenliği

- Komutu sadece operatör ve yönetici ekleyebilir; gateway kullanıcısı komut ekleyemez.
- Vana komutları **idempotent**tir: aynı `cmdId` iki kez gelirse vana bir kez değişir. Modbus adaptörü vana zaten istenen durumdaysa yazma yapmaz (`ALREADY_IN_STATE`).
- Uygulama önceki komut bitmeden yeni komut göndermez; gerçek durum sadece düğümün `CMD_RESULT` cevabıyla gösterilir.
- Gateway cihaza ulaşamazsa komutu `failed` (TIMEOUT) yapar; uygulama kullanıcıya bunu gösterir. Komutlar sonradan "sessizce" çalışmaz.
