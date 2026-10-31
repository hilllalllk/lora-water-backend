# 1 · Backend: Bulut Supabase'i kurmak

> Sıra: **1 Backend** → 2 Donanım (`lora-water-hardware` → `docs/kurulum.md`) → 3 Mobil (`lora-water-mobile` → `docs/kurulum.md`)
> Teknik ayrıntılar: 10 · Gateway ↔ Supabase (`lora-water-hardware` → `docs/10-gateway-supabase.md`)

**Amaç:** İnternette her zaman açık duran bir sunucu kurmak. Gateway ölçümleri buraya gönderecek, mobil
uygulama da verileri buradan okuyacak.

**Neden bulut:** Bilgisayarındaki Supabase yalnızca o bilgisayarda çalışır. Gateway ise güvenli bağlantı (HTTPS)
ister ve bilgisayarına ulaşamaz.

**Süre:** Yaklaşık 20 dakika. **Gerekenler:** İnternet, Node.js 22 ve bu repo.

Bütün komutlar `backend/` klasöründe çalıştırılır:

```bash
cd backend
```

---

## Adım 1: Supabase hesabı ve giriş

**Ne:** Bilgisayardaki Supabase aracına hesabını kullanma izni vermek.

1. Hesabın yoksa **https://supabase.com** adresinden ücretsiz hesap aç (GitHub ile giriş en kolayı).
2. Terminalde şunu çalıştır:

   ```bash
   npx supabase login
   ```

3. Tarayıcı açılır, **Authorize** butonuna bas.

✅ **Kontrol:** Terminalde `You are now logged in` yazar.

---

## Adım 2: Bulutta proje açmak

**Ne:** İnternette sana ait bir Supabase sunucusu açmak.

1. **https://supabase.com/dashboard** → **New project**.
2. Alanları doldur:

   | Alan | Değer |
   |---|---|
   | Name | `lora-water` |
   | Database Password | Güçlü bir şifre. **Bir yere not et**, Adım 3'te sorulacak. |
   | Region | **Central EU (Frankfurt)**, Türkiye'ye en yakın bölge |
   | Plan | Free |

3. **Create new project** butonuna bas ve 1-2 dakika bekle.
4. Adres çubuğundaki `https://supabase.com/dashboard/project/`**`abcdefghijkl`** kısmı **proje kimliğidir**
   (project ref). Not et.

✅ **Kontrol:** Panelde proje açılır ve yeşil "Healthy" görünür.

---

## Adım 3: Veritabanını yüklemek

**Ne:** Tabloları, kuralları ve gateway'in çağırdığı fonksiyonları buluta kopyalamak. Proje boş açılır; bu
adımdan sonra gateway'i karşılayacak her şey hazır olur.

```bash
npx supabase link --project-ref <proje-kimliği>    # bu klasörü buluttaki projeye bağlar (şifreyi sorar)
npx supabase db push                               # migration dosyalarını sırayla yükler
```

`db push` uygulanacak 13 dosyayı listeler ve onay ister. **Y** ile onayla.

> **Örnek cihazlar:** `npx supabase db push --include-seed` komutu `seed.sql` dosyasını da yükler. Bu dosyada üç
> prototip düğümü (`node-1001`, `node-1002`, `node-1003`) ve metin cihazı `DEPO_01` var; eşik değerleri de
> tanımlı. Gerçek sahada cihazları Adım 6'daki gibi kendin eklersin.

✅ **Kontrol:** Panelde **Table Editor** açıldığında `devices`, `telemetry`, `commands`, `gateways`, `alerts`
tabloları görünür.

---

## Adım 4: Metin gateway'inin sunucu fonksiyonunu yüklemek

**Ne:** `ingest-tank` adlı küçük bir sunucu programı. Sahadaki `DEPO_01,75,KAPALI` cihazının gateway'i
ölçümleri buraya gönderir. Yalnızca v1 gateway kullanacaksan bu adımı atlayabilirsin.

```bash
npx supabase functions deploy ingest-tank --no-verify-jwt
```

`--no-verify-jwt` şunun için gerekli: bu gateway hesapla giriş yapmaz, kendini cihaz anahtarıyla tanıtır
(Adım 6).

✅ **Kontrol:** Panelde **Edge Functions** altında `ingest-tank` görünür.

---

## Adım 5: Kullanıcıları açmak

Panelde **Authentication → Users → Add user → Create new user**. Her kullanıcı için **Auto Confirm User**
seçeneğini işaretle.

| Kullanıcı | Örnek e-posta | Ne için |
|---|---|---|
| Sen (yönetici) | kendi e-postan | Mobil uygulamaya girip her şeyi yönetmek |
| Gateway (yalnızca v1) | `gateway@ornek.com` | v1 gateway sunucuya bu hesapla girer |

Ardından **SQL Editor**'de şunu çalıştır (e-postaları kendi yazdıklarınla değiştir):

```sql
-- Seni yönetici yapar (yeni kullanıcılar "İzleyici" olarak başlar)
update public.profiles set role = 'admin'
 where id = (select id from auth.users where email = 'sen@ornek.com');

-- Gateway hesabına "gateway" rolünü verir. Bu rol yalnızca ölçüm gönderip komut alabilir.
update auth.users
   set raw_app_meta_data = raw_app_meta_data || '{"role": "gateway"}'
 where email = 'gateway@ornek.com';
```

✅ **Kontrol:** Her iki komut da `Success. 1 row` döner.

---

## Adım 6: Depoları (cihazları) eklemek

**SQL Editor**'de çalıştırılır.

**Metin cihazı** (sahadaki `DEPO_01`; `--include-seed` kullandıysan zaten eklidir, `insert` hiçbir şeyi değiştirmez):

```sql
insert into public.devices (id, code, protocol, name, type, capacity_mm)
values ('depo-01', 'DEPO_01', 'text', 'Depo-01 (saha)', 'tank', 1000)  -- capacity_mm: depo yüksekliği (mm)
on conflict (id) do nothing;

-- Metin gateway'inin anahtarı. Çıktıdaki "lwm_..." değerini HEMEN not et; bir daha gösterilmez.
select public.issue_ingest_token('gw-text-01', 'Saha 1');
```

**v1 düğümleri:** Adım 3'te `--include-seed` kullandıysan üç örnek düğüm zaten eklidir. Gateway düğümleri radyo
adreslerinden tanır: `node-1001` düğümünün adresi `0x1001`, yani `4097`.

> Kutu kaybolursa ya da anahtar ele geçerse iptal edip yenisini üretirsin:
> `update public.ingest_tokens set revoked_at = now() where gateway_id = 'gw-text-01';`

✅ **Kontrol:** **Table Editor → devices** tablosunda depolar görünür.

---

## Adım 7: Adres ve anahtarı almak

Panelde **Project Settings → API** (yeni panellerde **API Keys**) sayfasına git ve not et:

| Ne | Örnek | Nerede kullanılacak |
|---|---|---|
| Project URL | `https://abcdefghijkl.supabase.co` | Gateway ve mobil uygulama |
| `anon` / publishable key | `eyJ...` ya da `sb_publishable_...` | Gateway (v1) ve mobil uygulama |

> ⚠️ Aynı sayfadaki **`service_role` / secret** anahtarını **hiçbir yere koyma**. Bu anahtar bütün güvenlik
> kurallarını atlar.

---

## Adım 8: Sunucuyu test etmek (kart gerekmez)

Gateway'in yapacağı isteği bilgisayardan elle gönderiyoruz. Cevap gelirse backend hazır demektir.

```bash
URL=https://<proje-kimliği>.supabase.co
ANON=<anon-key>

# v1 gateway: önce gateway hesabıyla giriş, sonra gateway_sync çağrısı
TOKEN=$(curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"email":"gateway@ornek.com","password":"<gateway-şifresi>"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
curl -s -X POST "$URL/rest/v1/rpc/gateway_sync" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"p":{"gateway_id":"gw-test","claim":false}}'
```

✅ Beklenen cevap: `{"ingest": null, "reports": [], "command": null, "poll_ms": 3000, "errors": []}`

```bash
# Metin gateway'i: test ölçümü
curl -i -X POST "$URL/functions/v1/ingest-tank" -H "X-Device-Token: lwm_..." -H "X-Request-Id: test-1" \
  -H "Content-Type: application/json" -d '{"device_id":"DEPO_01","level_percent":75,"valve_state":"KAPALI"}'
```

✅ Beklenen cevap: `HTTP/2 201`. Aynı komut ikinci kez çalıştırılırsa `200` döner ve yeni satır oluşmaz.

Testten sonra SQL Editor'de deneme kayıtlarını silebilirsin: `delete from public.gateways where id = 'gw-test';`

---

## Sorun çıkarsa

| Hata | Neden | Çözüm |
|---|---|---|
| `AccessTokenRequiredError` | Giriş yapılmamış | Adım 1 |
| `db push`: `password authentication failed` | Veritabanı şifresi yanlış | Panelde **Project Settings → Database → Reset password** |
| `gateway_sync`: `403 Only the gateway can sync` | Gateway rolü verilmemiş | Adım 5'teki `update auth.users ...` |
| `gateway_sync`: `404 PGRST202` | Migration'lar yüklenmemiş ya da gövde `{"p": ...}` ile sarılmamış | Adım 3 |
| `ingest-tank`: `401` | Anahtar yanlış ya da iptal edilmiş | Adım 6'da yeni anahtar üret |
| `ingest-tank`: `404` | `DEPO_01` cihazı eklenmemiş | Adım 6 |

**Bitti mi?** Adım 8'deki iki test de beklenen cevabı döndüyse backend hazır. Sıradaki: 2 · Donanım (`lora-water-hardware` → `docs/kurulum.md`).

**Bir sonraki dosyaya taşınacak bilgiler:** Project URL, anon key, gateway e-postası ve şifresi, `lwm_...`
anahtarı.
