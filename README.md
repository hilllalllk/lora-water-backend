# Backend (Supabase)

```
backend/supabase/
├── migrations/
│   ├── 20261014000000_init.sql          # tables, triggers, RLS, Realtime
│   ├── 20261018000000_roles_alarms.sql  # roles, alarm thresholds, alerts, push tokens
│   ├── 20261101000000_command_expired_status.sql  # 'expired' status (own transaction)
│   ├── 20261101000100_command_lifecycle.sql       # validation, expiry, state machine, claim
│   ├── 20261101000200_telemetry_ingest.sql        # idempotent batch ingest, late rows
│   └── 20261101000300_read_models.sql             # hourly rollup, chart series, overview
├── functions/send-alert-push/index.ts   # Edge Function: alert -> Expo push notification
├── seed.sql                             # sample devices and thresholds
└── tests/
    ├── supabase_stub.sql                # emulates Supabase's auth schema on plain PostgreSQL (TEST ONLY)
    ├── rls_test.sql                     # permission and trigger tests (init schema)
    ├── roles_alarms_test.sql            # roles, thresholds, alerts, push token tests
    ├── lifecycle_test.sql               # command lifecycle, ingest, read models
    └── run.sh                           # runs the tests
```

## Tables

| Table | Contents | Written by |
|---|---|---|
| `devices` | Nodes and their latest state | Admin (insert), gateway (heartbeat), trigger (latest reading) |
| `telemetry` | Measurement history | Gateway only |
| `commands` | Command queue and status | Operator/admin (inserts `pending`), gateway (updates status) |
| `gateways` | Gateway health | Gateway only |
| `profiles` | One row per user: `full_name`, `role` | Trigger on `auth.users` (insert), admin (role), user (own `full_name`) |
| `alerts` | Alarm events, open while `resolved_at` is null | Triggers / `check_offline_devices()` only |
| `push_tokens` | Expo push tokens of users' phones | Each user, own rows only |

## Roles

| Role | Can |
|---|---|
| `admin` (Yönetici) | Everything below, plus change users' roles and device alarm thresholds |
| `operator` (Operatör) | Send commands |
| `viewer` (İzleyici) | Read only (default for new users) |

The role lives in `public.profiles.role`; policies use `public.has_role('operator', 'admin')`. The gateway is separate: it is identified by `app_metadata.role = 'gateway'` (`public.is_gateway()`), has no app role and cannot send commands.

The first admin must be set from the SQL Editor (after the user exists in Authentication > Users):

```sql
update public.profiles set role = 'admin'
 where id = (select id from auth.users where email = 'you@example.com');
```

After that, admins manage roles from the app's "Kullanıcılar" screen. The last admin cannot be demoted.

## Alarm thresholds and alerts

`devices` has nullable thresholds `level_low_mm`, `level_high_mm`, `pressure_low_cbar`, `pressure_high_cbar` and `offline_after_s` (default 600). Null disables that check. Only admins can change them; admins cannot change the device state columns written by the gateway.

- Every telemetry insert is checked (`telemetry_alerts` trigger). When a condition starts an alert is opened (at most one open alert per device and kind); when the value is back to normal it is resolved. A non-zero `alarms` bitmask opens a `device_alarm` alert.
- `public.check_offline_devices()` opens `offline` alerts for devices silent longer than `offline_after_s`. The migration schedules it every minute with pg_cron when the extension is available (it is on Supabase; check Database > Cron). The alert is resolved as soon as the device is heard again (telemetry or gateway heartbeat).
- `alerts` is in the Realtime publication, so the app updates live.


The gateway is an ESP32 on Wi-Fi. It signs in as the gateway user and polls pending `commands` over the REST API every 1-2 s.

Setup: [docs/05-kurulum.md §1](../docs/05-kurulum.md#1-supabase-projesi). Design: [docs/02 §6](../docs/02-sistem-mimarisi.md#6-supabase-veri-modeli).

## Layers and entry points

Writes go through database functions (RPC); reads use RLS-protected tables and views.
Decision and rationale: [ADR-0009](../docs/adr/0009-veritabani-katmanlari-komut-yasam-dongusu.md).

| Caller | Function | What it does |
|---|---|---|
| App (operator, admin) | `send_command(device_id, op, args)` | Validates and queues a command; Turkish error messages |
| App (all) | `telemetry_series(device_id, from, to, points)` | Chart series in `points` buckets (raw or hourly data) |
| App (all) | `device_overview` (view) | Device + open alert count + unfinished command |
| Gateway | `claim_next_command()` | Takes the oldest live pending command and marks it `sent` |
| Gateway | `ingest_telemetry(rows)` | Batch insert (max 100), safe to resend with `ingest_key` |
| pg_cron | `expire_commands()` | Every minute: `pending` past its deadline → `expired`; stuck `sent`/`delivered` → `failed` |
| pg_cron | `rollup_telemetry_hourly()` / `cleanup_old_telemetry(90)` | Hourly sums; raw rows kept 90 days |

Command states: `pending → sent → delivered → done | failed`, and `pending → expired`.
A command waits at most 2 minutes (`command_ttl()`); a device has at most one unfinished command.

## Push notifications

New alerts are pushed to phones by the Edge Function `send-alert-push`, triggered by a Database Webhook.

1. Deploy the function (Supabase CLI, from `backend/`):

   ```bash
   supabase login
   supabase link --project-ref <project-ref>
   supabase functions deploy send-alert-push --no-verify-jwt
   ```

   `--no-verify-jwt` lets the webhook call it without a user JWT; protect it with the secret below. (Alternatively keep JWT verification and let the webhook send the service role key as `Authorization: Bearer ...`.)

2. Set the secrets (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are already provided to Edge Functions):

   ```bash
   supabase secrets set WEBHOOK_SECRET=<long random string>
   # only if you enabled "enhanced push security" for the Expo project:
   supabase secrets set EXPO_ACCESS_TOKEN=<expo access token>
   ```

3. Create the webhook in the dashboard: Database > Webhooks > Create a new hook
   - Table: `public.alerts`, Events: **Insert**
   - Type: Supabase Edge Functions, function `send-alert-push`, method POST
   - HTTP headers: add `x-webhook-secret: <same value as WEBHOOK_SECRET>`

The function reads all `push_tokens` with the service role, sends to the Expo push API in chunks of 100 (title `Alarm: <device name>`, body = alert message) and deletes tokens Expo reports as `DeviceNotRegistered`. The app registers its token with `public.register_push_token()` after sign-in (see `mobile/README.md`).

## Tests

```bash
# Against a local PostgreSQL (PGHOST, PGUSER, PGPASSWORD must be set)
bash backend/supabase/tests/run.sh
```

`run.sh` creates a fresh database per test file, applies the stub and all migrations in order, then runs the test. pg_cron is not needed locally (the migration skips the schedule with a notice).

If you change the schema, add a new migration file (`YYYYMMDDHHMMSS_description.sql`) and add tests to a test file listed in `run.sh`.
