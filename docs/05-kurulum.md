# 05 · Kurulum Rehberi

Bu rehber sıfırdan çalışan bir sistem kurmak için gereken adımları sırasıyla anlatır. Her adımın sonunda bir "Kontrol" satırı var; o çalışmadan sonraki adıma geçmeyin. Windows'a özel notlar [§6](#6-windows)'dadır.

## 0. Gerekli araçlar

| Araç | Ne için | İndirme |
|---|---|---|
| Git | Repoyu indirmek (Windows'ta Git Bash da gelir) | https://git-scm.com |
| VS Code + **PlatformIO IDE** eklentisi | Uç düğüm ve gateway firmware'ini derleyip yüklemek | https://platformio.org/install/ide?install=vscode |
| Node.js **22 LTS** | Mobil uygulama, çerçeve aracı (`tools/`), Supabase CLI (`npx`) | https://nodejs.org |
| USB-UART sürücüsü (CP210x veya CH340) | ESP32 kartını bilgisayarın görmesi için (kartın üzerindeki çipe göre) | Silicon Labs / WCH |
| Telefonda **Expo Go** | Uygulamayı geliştirirken telefonda açmak | App Store / Google Play |
| Supabase hesabı | Veritabanı, Auth, Edge Function | https://supabase.com |
| Expo hesabı (ücretsiz) | Android APK üretmek (EAS Build) | https://expo.dev |
| GitHub CLI (`gh`, isteğe bağlı) | Issue ve proje panosunu oluşturmak | https://cli.github.com |

```bash
git clone https://github.com/hilllalllk/lora-water-management.git
cd lora-water-management
```

## 1. Supabase projesi

1. Supabase'de **New project** oluşturun. Plan: **Free**. Bölge: **Central EU (Frankfurt)**, `eu-central-1`.
2. **SQL Editor**'de migration dosyalarını **sırayla** çalıştırın (her birinin tamamını yapıştırıp **Run**):
   1. [`backend/supabase/migrations/20261014000000_init.sql`](../supabase/migrations/20261014000000_init.sql): tablolar, tetikleyiciler, RLS, Realtime
   2. [`backend/supabase/migrations/20261018000000_roles_alarms.sql`](../supabase/migrations/20261018000000_roles_alarms.sql): roller, eşikler, alarmlar, push token'ları, pg_cron görevi
3. Aynı yerde [`backend/supabase/seed.sql`](../supabase/seed.sql) dosyasını çalıştırın (üç örnek cihaz ve eşikleri: `node-1001`, `node-1002`, `node-1003`).
4. **Authentication → Users → Add user** ile iki kullanıcı oluşturun:
   - Kendi kullanıcınız (mobil uygulamaya bununla gireceksiniz)
   - Gateway kullanıcısı, ör. `gateway@ornek.com` (güçlü bir şifre; bu bilgiler §4.4'te `secrets.h` dosyasına yazılacak)
5. Gateway kullanıcısına `gateway` rolünü verin (SQL Editor):

   ```sql
   update auth.users
      set raw_app_meta_data = raw_app_meta_data || '{"role": "gateway"}'
    where email = 'gateway@ornek.com';
   ```

6. Kendinizi **ilk yönetici** yapın (yeni kullanıcılar `viewer` başlar):

   ```sql
   update public.profiles set role = 'admin'
    where id = (select id from auth.users where email = 'siz@ornek.com');
   ```

   Sonraki kullanıcıların rolleri uygulamadaki "Kullanıcılar" ekranından verilir.
7. **Project Settings → API** sayfasından not edin: Project URL (`https://xxxx.supabase.co`), `anon` (yeni panellerde **publishable**) anahtar ve proje kimliği (project ref).

> **`service_role` (secret) anahtarını hiçbir cihaza, uygulamaya veya dosyaya koymayın.** Bu anahtar tüm RLS kurallarını atlar; sadece Edge Function'a Supabase tarafından otomatik verilir.

**Kontrol:** Table Editor'de `devices` tablosunda üç cihaz, `profiles` tablosunda kendi satırınız `admin` rolüyle görünüyor. **Database → Cron**'da `check-offline-devices` görevi her dakika çalışıyor.

## 2. Alarm bildirimleri (Edge Function + webhook)

Ayrıntı: [`backend/README.md`](../README.md#push-notifications). Komutlar `backend/` klasöründen çalıştırılır; Supabase CLI `npx` ile kurulumsuz kullanılır.

```bash
cd backend
npx supabase login
npx supabase link --project-ref <project-ref>
npx supabase functions deploy send-alert-push --no-verify-jwt
npx supabase secrets set WEBHOOK_SECRET=<uzun-rastgele-metin>
# sadece Expo projesinde "enhanced push security" açıksa:
npx supabase secrets set EXPO_ACCESS_TOKEN=<expo-access-token>
```

Panelde **Database → Webhooks → Create a new hook**:

| Alan | Değer |
|---|---|
| Table | `public.alerts` |
| Events | **Insert** |
| Type | Supabase Edge Functions → `send-alert-push`, POST |
| HTTP headers | `x-webhook-secret: <WEBHOOK_SECRET ile aynı değer>` |

`SUPABASE_URL` ve `SUPABASE_SERVICE_ROLE_KEY` Edge Function ortamına Supabase tarafından verilir; elle eklenmez.

**Kontrol:** **Edge Functions** sayfasında `send-alert-push` görünüyor; webhook listede.

## 3. Donanımı bağlama

04 · Donanım (`lora-water-hardware` → `docs/04-donanim.md`) dokümanındaki şemalara göre:

- Her ESP32'yi bir E32-433T20D'ye bağlayın (04 §2.1 (`lora-water-hardware` → `docs/04-donanim.md`)). Gateway'in bağlantısı da aynıdır.
- `node` / `node2`: LED (GPIO2) ve potansiyometre (GPIO34).
- `node-modbus`: MAX3485 (GPIO25 / 26 / 27) ve kontrol cihazı ya da USB-RS485 çevirici.

Antenleri takın. Kartları USB'den besleyin; ayrı güç kaynağı gerekmez.

## 4. Firmware (uç düğüm ve gateway)

VS Code'da `firmware/` klasörünü açın; PlatformIO projeyi tanır. Komutlar PlatformIO terminalinde (`pio`) çalışır. Ayrıntı: `firmware/README.md` (`lora-water-hardware` → `firmware/README.md`).

### 4.1 Testler (kart gerekmez)

```bash
pio test -e native
```

**Kontrol:** protokol (16) ve Modbus (11) testleri geçiyor: `27 test cases: 27 succeeded`.

### 4.2 Simüle düğüm (`node`, `node2`)

```bash
pio run -e node -t upload      # adres 0x1001
pio device monitor             # 115200 baud
```

İkinci düğüm için `-e node2` (0x1002). Uç düğümde Wi-Fi veya Supabase bilgisi yoktur.

**Kontrol:** Seri monitörde `[node] address=0x1001 fw=0.1.0 device=...` ve periyodik `[node] telemetry: level=... valve=...` satırları. Gateway yokken `[node] no ACK received for SEQ ...` normaldir.

### 4.3 Modbus düğümü (`node-modbus`)

Gerçek kontrol cihazı yoksa bilgisayar Modbus slave olur:

1. USB-RS485 çeviriciyi bilgisayara takın; A/B uçlarını MAX3485'in A/B uçlarına, GND'yi GND'ye bağlayın.
2. Çeviricinin seri portunda bir slave simülatörü başlatın: 9600 baud, 8N1, slave ID 1, holding register 0–11 (adres 0'dan 12 register).
   - Windows: **ModRSsim2** (ücretsiz) veya **Modbus Slave**
   - Komut satırı: `diagslave -m rtu -a 1 -b 9600 -d 8 -s 1 -p none COM5` (Linux'ta `/dev/ttyUSB0`)
3. Yükleyin:

   ```bash
   pio run -e node-modbus -t upload   # adres 0x1003
   pio device monitor
   ```

**Kontrol:** Açılışta `[modbus] slave 1 online`. Simülatörde register 0–4'ü değiştirince telemetri değişiyor; uygulamadan "Vana aç" sonrası register 10 = 1 oluyor. Cevap yoksa A/B'yi ters çevirin, baud ve slave ID'yi kontrol edin.

Register haritası `firmware/include/modbus_map.h` (`lora-water-hardware` → `firmware/include/modbus_map.h`) dosyasındadır; gerçek cihaz için sadece bu dosya değişir.

### 4.4 Gateway (`gateway`)

1. Gizli bilgi dosyasını oluşturun (`secrets.h` Git'e girmez):

   ```bash
   cp include/secrets.example.h include/secrets.h
   ```

   Windows (cmd): `copy include\secrets.example.h include\secrets.h`

2. `include/secrets.h` içini doldurun:

   | Ad | Değer |
   |---|---|
   | `WIFI_SSID`, `WIFI_PASSWORD` | 2,4 GHz Wi-Fi (ESP32 5 GHz desteklemez) |
   | `SUPABASE_URL` | §1.7'deki Project URL |
   | `SUPABASE_ANON_KEY` | `anon` / publishable anahtar (**`service_role` asla**) |
   | `GATEWAY_EMAIL`, `GATEWAY_PASSWORD` | §1.4'teki gateway kullanıcısı |
   | `GATEWAY_ID` | `gateways` tablosundaki ad, ör. `gw-01` |

3. Yükleyin:

   ```bash
   pio run -e gateway -t upload
   pio device monitor
   ```

Gateway açılışta saati NTP ile ayarlar (ağ UDP 123'e izin vermeli), sonra TLS sertifikasını doğrulayarak bağlanır.

**Kontrol:** Seri monitörde sırasıyla `[gw] Wi-Fi connected, IP=...`, `[gw] clock set: ... UTC`, `[gw] signed in to Supabase`, `[gw] loaded 3 devices`. Düğüm açıkken `telemetry` tablosuna satırlar düşüyor; `gateways` tablosunda `gw-01` satırının `last_seen` ve `wifi_rssi` değeri her dakika yenileniyor.

### 4.5 Metin gateway'i (`gateway-text`): sahadaki DEPO_01 donanımı

Mevcut verici `DEPO_01,75,KAPALI` gönderir ve değişmez (ADR-0011 (`lora-water-management` → `docs/adr/0011-metin-protokolu-ingest-tank.md`), 03 §10 (`lora-water-hardware` → `docs/03-protokol.md`)). Gateway kablolaması da aynı kalır: E32 TXD → GPIO16, E32 RXD → GPIO17, M0 ve M1 → GND, AUX boş.

1. **Supabase.** Migration'lar §1'deki gibi yüklenmiş olmalı. Komutlar `backend/` klasöründen çalıştırılır.

   ```bash
   npx supabase functions deploy ingest-tank --no-verify-jwt
   ```

   SQL Editor'de cihazı ekleyin ve gateway token'ı üretin. Token yalnızca bu çıktıda görünür; gateway'e güvenli bir kanaldan iletin:

   ```sql
   insert into public.devices (id, code, protocol, name, type, capacity_mm)
   values ('depo-01', 'DEPO_01', 'text', 'Depo-01 (saha)', 'tank', 1000)   -- capacity_mm: depo yüksekliği (mm)
   on conflict (id) do nothing;
   select public.issue_ingest_token('gw-text-01', 'Saha 1');                 -- lwm_... döner
   ```

   Token'ı iptal etmek için: `update public.ingest_tokens set revoked_at = now() where gateway_id = 'gw-text-01';`, ardından yeni token üretin.

2. **Firmware.** `include/secrets.h` (§4.4) içinde `WIFI_SSID`, `WIFI_PASSWORD`, `SUPABASE_URL` ve `INGEST_TOKEN` doldurulur. Gateway kullanıcısı ve anon anahtar bu ortamda gerekmez; **service_role anahtarı asla girilmez**.

   ```bash
   pio run -e gateway-text -t upload
   pio device monitor
   ```

3. **Kabul testleri** (devir dokümanı §8). `URL=<SUPABASE_URL>/functions/v1/ingest-tank` ve `TOKEN=lwm_...` ile:

   | # | Yapılacak | Beklenen |
   |---|---|---|
   | 1 | Vericiyi açın | Seri monitörde `LoRa alindi: DEPO_01,75,KAPALI` |
   | 2 | Gateway Wi-Fi'ye bağlansın | `Supabase HTTP: 201 (DEPO_01, 75%)` |
   | 3 | SQL Editor: `select * from tank_readings order by id desc limit 5;` | `device_id = DEPO_01`, `level_percent = 75` satırı; uygulamada Depo-01 kartı %75 |
   | 4 | Modemin internetini kesin | Verici `ACK,75` almaya devam eder, yeni satır oluşmaz; `Wi-Fi yok` ya da `Supabase HTTP: -1` loglanır. İnternet dönünce bekleyen okumalar sırayla 201 alır |
   | 5 | Geçersiz istekler (aşağıda) | 400 / 401 / 405 |

   ```bash
   # 201 (aynı X-Request-Id ile ikinci kez: 200, yeni satır yok)
   curl -i -X POST "$URL" -H "X-Device-Token: $TOKEN" -H "X-Request-Id: test-1" \
     -H "Content-Type: application/json" -d '{"device_id":"DEPO_01","level_percent":75,"valve_state":"KAPALI"}'
   # 400: seviye 150
   curl -i -X POST "$URL" -H "X-Device-Token: $TOKEN" \
     -H "Content-Type: application/json" -d '{"device_id":"DEPO_01","level_percent":150,"valve_state":"KAPALI"}'
   # 401: yanlış token
   curl -i -X POST "$URL" -H "X-Device-Token: yanlis" \
     -H "Content-Type: application/json" -d '{"device_id":"DEPO_01","level_percent":75,"valve_state":"KAPALI"}'
   # 405: GET
   curl -i "$URL"
   ```

**Not:** Gateway'in "bağlı" görünmesi için ölçümler gateway çevrimdışı eşiğinden sık gelmelidir; çünkü gateway kendi canlılığını yalnızca ölçüm gönderirken bildirir. Metin düğümleri komut almaz; uygulama bu depolarda vana kaydırıcısını göstermez.

## 5. Mobil uygulama

Ayrıntı: `mobile/README.md` (`lora-water-mobile` → `README.md`).

### 5.1 Geliştirme (Expo Go)

```bash
cd mobile
npm install
cp .env.example .env.local     # EXPO_PUBLIC_SUPABASE_URL ve EXPO_PUBLIC_SUPABASE_KEY
npx expo start
```

Terminaldeki QR kodu telefonda okutun (Android: Expo Go, iPhone: Kamera uygulaması). Telefon ve bilgisayar aynı Wi-Fi'de olmalı; olmuyorsa `npx expo start --tunnel`. §1.4'teki kendi kullanıcınızla giriş yapın.

**Kontrol:** Cihaz listesinde `Depo-1 (prototip)` çevrimiçi; potansiyometreyi çevirince seviye birkaç saniyede değişiyor; detayda 24 saat grafiği çiziliyor. "Vana aç" ile LED yanıyor ve komut "Tamamlandı" oluyor. Seviyeyi alt eşiğin (300 mm) altına indirince "Alarmlar" listesinde alarm açılıyor.

### 5.2 Android APK (EAS Build)

```bash
npm install -g eas-cli
eas login
eas init                       # app.json'a extra.eas.projectId yazar
eas env:create --environment preview --name EXPO_PUBLIC_SUPABASE_URL --value https://xxxx.supabase.co --visibility plaintext
eas env:create --environment preview --name EXPO_PUBLIC_SUPABASE_KEY --value <anon-veya-publishable> --visibility plaintext
npm run build:apk              # = eas build -p android --profile preview
```

Build bitince EAS'in verdiği bağlantıdan `.apk` indirilip telefona kurulur ("bilinmeyen uygulamalara izin ver"). Uygulama mağazalarda yayınlanmaz.

### 5.3 Push bildirimi

- **Android'de Expo Go push desteklemez**; push APK ile test edilir.
- Android için FCM V1 bilgileri gerekir: Firebase projesinde `com.lorawater.mobile` paketli Android uygulaması açılır, `google-services.json` `mobile/` klasörüne konur ve `app.json`'da `expo.android.googleServicesFile` olarak eklenir; FCM V1 servis hesabı anahtarı `eas credentials` ile EAS'e yüklenir; APK yeniden üretilir.
- iPhone'da Expo Go ile geliştirme sırasında push alınabilir; bağımsız iOS kurulumu Apple geliştirici hesabı gerektirir.
- Emülatörde push çalışmaz.

**Kontrol:** APK ile giriş yapınca bildirim izni soruluyor; `push_tokens` tablosuna bir satır ekleniyor. Bir eşik aşılınca telefona "Alarm: <cihaz adı>" bildirimi geliyor. Gelmiyorsa cihaz günlüğünde `[push] skipped: ...` satırına ve Edge Function günlüklerine bakın.

## 6. Windows

Proje Windows'ta aynı adımlarla çalışır. Farklar:

| Konu | Windows'ta |
|---|---|
| Kurulacaklar | Node.js 22 LTS, Git (Git Bash ile), VS Code + PlatformIO, kartın USB sürücüsü (CP210x veya CH340) |
| Seri port | Kart `COM3`, `COM5` gibi görünür (Aygıt Yöneticisi → Bağlantı noktaları). PlatformIO portu kendisi bulur; bulamazsa `pio run -e node -t upload --upload-port COM5` |
| Dosya kopyalama | `cp` yerine `copy`: `copy .env.example .env.local`, `copy include\secrets.example.h include\secrets.h` (PowerShell'de `cp` de çalışır) |
| Expo | Telefon bilgisayara ulaşamıyorsa (kampüs/şirket ağı, güvenlik duvarı) `npx expo start --tunnel`; Windows Güvenlik Duvarı sorunca Node.js'e izin verin |
| iOS | Windows'ta iOS simülatörü yok; gerçek iPhone'da Expo Go kullanılır. Android için gerçek telefon veya Android Studio emülatörü |
| APK | EAS Build bulutta çalıştığı için Windows'tan da üretilir |
| Bash betikleri | `bash scripts/github-issues.sh` ve `bash backend/supabase/tests/run.sh` Git Bash'ten çalıştırılır |
| Modbus simülatörü | ModRSsim2 veya Modbus Slave; USB-RS485 çevirici bir `COM` portu olarak görünür |

## 7. Sorun giderme

| Belirti | Olası neden | Çözüm |
|---|---|---|
| `WARNING: could not verify E32 configuration` | M0/M1/AUX veya TX/RX ters bağlı, besleme yetersiz | Bağlantıları kontrol edin; TXD↔RX ve RXD↔TX çapraz olmalı |
| ESP32 iletimde yeniden başlıyor | E32 3V3'ten besleniyor, gerilim düşüyor | E32'yi VIN (5 V) ile besleyin, 100 µF kondansatör ekleyin |
| Bilgisayar kartı görmüyor | USB sürücüsü yok veya kablo sadece şarj kablosu | CP210x/CH340 sürücüsünü kurun, veri kablosu kullanın |
| Düğümde hep `no ACK received` | Gateway kapalı veya farklı kanal / hava hızı | Düğüm ve gateway aynı firmware ayarlarıyla derlenmeli |
| `[gw] unknown address 0x1001` | Adres `devices` tablosunda yok | `devices.address` = 4097 (0x1001); gateway listeyi 5 dakikada bir yeniler |
| Gateway `NTP sync failed` | Ağ UDP 123'ü engelliyor | Başka ağ (ör. telefon hotspot) deneyin |
| Gateway TLS / sertifika hatası | Saat ayarlı değil veya Supabase kök sertifikası değişti | NTP satırına bakın; kök değiştiyse `root_ca.h`'ye ekleyin (`firmware/README.md` (`lora-water-hardware` → `firmware/README.md`)) |
| `[gw] Supabase sign-in failed` veya yetki hatası | Gateway şifresi yanlış veya rol verilmemiş | §1.5'teki SQL'i çalıştırın, `secrets.h`'yi kontrol edin |
| `[modbus] slave 1 not responding at boot` | A/B ters, yanlış baud / slave ID, DE/RE bağlı değil | §4.3 |
| Uygulamada komut butonları yok | Kullanıcı `viewer` | Yönetici "Kullanıcılar" ekranından rol verir (ilk yönetici §1.6) |
| Komut eklerken yetki hatası | Kullanıcı operatör / yönetici değil | Aynı |
| Uygulama "Supabase ayarları eksik" | `.env.local` yok | `.env.local` oluşturun, `npx expo start -c` |
| Veri var ama canlı güncellenmiyor | Realtime yayını eksik | Migration'lar eksiksiz çalışmış olmalı |
| Alarm açılıyor ama push gelmiyor | Expo Go (Android), FCM bilgisi yok, webhook başlığı yanlış | §5.3, §2 |
| `offline` alarmı hiç açılmıyor | pg_cron görevi yok | Database → Cron'da `check-offline-devices` görevini kontrol edin |

## 8. Testler ve iş takibi (geliştiriciler için)

| Bölüm | Komut | Gerekenler |
|---|---|---|
| Protokol + Modbus (C++, 27 test) | `cd firmware && pio test -e native` | PlatformIO |
| Firmware derlemesi | `cd firmware && pio run -e node -e node2 -e node-modbus -e gateway` | PlatformIO, `include/secrets.h` |
| Araçlar (TypeScript, 19 test) | `cd tools && npm ci && npm test` | Node.js 22 |
| Veritabanı (2 dosya, 35 kontrol) | `bash backend/supabase/tests/run.sh` | PostgreSQL (`PGHOST`, `PGUSER`, `PGPASSWORD`) |
| Edge Function tip kontrolü | `deno check backend/supabase/functions/*/index.ts` | Deno |
| Mobil tip kontrolü | `cd mobile && npm run typecheck` | Node.js 22 |

GitHub'a her gönderimde bu testler CI (`lora-water-management` → `.github/workflows/ci.yml`) ile çalışır (firmware, tools, database, edge-functions, mobile).

İş takibi GitHub Projects + Issues ile yapılır. Etiketleri, A1–A8 aşama issue'larını ve panoyu bir kez oluşturmak için (Windows'ta Git Bash):

```bash
gh auth login
gh auth refresh -s project
bash scripts/github-issues.sh
```
