-- LoRa Water Management System - alerts without storms, reliable push delivery
--
--   * Hysteresis: an alert opens when a value crosses its threshold and resolves only
--     after the value is back inside by devices.level_hysteresis_mm /
--     pressure_hysteresis_cbar. A level hovering at the threshold no longer opens and
--     closes an alert (and sends a push) on every packet.
--   * Re-open cooldown: an alert that re-opens within alert_cooldown() of the previous
--     one of the same device and kind is recorded but marked suppressed (no push).
--   * Gateway offline: one 'gateway_offline' alert per silent gateway. While no gateway
--     is online, device 'offline' alerts are still recorded but suppressed, so a gateway
--     outage sends one push instead of one per device.
--   * Push outbox: alerts.notified_at / notify_attempts. The Edge Function claims an
--     alert with claim_alert_notification() and confirms with finish_alert_notification();
--     retry_alert_notifications() (pg_cron + pg_net) re-sends alerts whose push failed.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
create or replace function public.alert_cooldown() returns interval
  language sql immutable as $$ select interval '10 minutes' $$;

create or replace function public.gateway_offline_after() returns interval
  language sql immutable as $$ select interval '3 minutes' $$;

-- Private settings for the push retry job (never exposed through the API).
--   insert into private.settings values
--     ('push_function_url', 'https://<project>.supabase.co/functions/v1/send-alert-push'),
--     ('push_webhook_secret', '<same value as the WEBHOOK_SECRET function secret>');
create schema if not exists private;
revoke all on schema private from public;
create table if not exists private.settings (
  key   text primary key,
  value text not null
);
revoke all on private.settings from public;

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.devices
  add column level_hysteresis_mm      integer not null default 20 check (level_hysteresis_mm >= 0),
  add column pressure_hysteresis_cbar integer not null default 10 check (pressure_hysteresis_cbar >= 0);

alter table public.alerts
  alter column device_id drop not null,
  add column gateway_id        text references public.gateways(id) on delete cascade,
  add column suppressed        boolean not null default false,
  add column notified_at       timestamptz,
  add column notify_attempts   smallint not null default 0,
  add column notify_claimed_at timestamptz,
  add column notify_error      text,
  add constraint alerts_one_subject check (num_nonnulls(device_id, gateway_id) = 1);

alter table public.alerts drop constraint alerts_kind_check;
alter table public.alerts add constraint alerts_kind_check
  check (kind in ('level_low', 'level_high', 'pressure_low', 'pressure_high', 'offline',
                  'device_alarm', 'gateway_offline'));

-- Alerts from before this migration were already handled by the old webhook
update public.alerts set notified_at = created_at;

create unique index alerts_one_open_gateway_idx on public.alerts (gateway_id, kind)
  where resolved_at is null and gateway_id is not null;
-- Outbox scan of the retry job
create index alerts_unnotified_idx on public.alerts (created_at)
  where notified_at is null and not suppressed;

-- ---------------------------------------------------------------------------
-- Thresholds are admin-only; the hysteresis columns count as thresholds
-- ---------------------------------------------------------------------------
create or replace function public.guard_device_update() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  rest public.devices;
begin
  if auth.uid() is null then
    return new;
  end if;

  if (new.level_low_mm, new.level_high_mm, new.pressure_low_cbar, new.pressure_high_cbar,
      new.offline_after_s, new.level_hysteresis_mm, new.pressure_hysteresis_cbar)
     is distinct from
     (old.level_low_mm, old.level_high_mm, old.pressure_low_cbar, old.pressure_high_cbar,
      old.offline_after_s, old.level_hysteresis_mm, old.pressure_hysteresis_cbar)
     and not public.has_role('admin') then
    raise exception 'Only an admin can change alarm thresholds'
      using errcode = 'insufficient_privilege';
  end if;

  rest := new;
  rest.name := old.name;
  rest.level_low_mm := old.level_low_mm;
  rest.level_high_mm := old.level_high_mm;
  rest.pressure_low_cbar := old.pressure_low_cbar;
  rest.pressure_high_cbar := old.pressure_high_cbar;
  rest.offline_after_s := old.offline_after_s;
  rest.level_hysteresis_mm := old.level_hysteresis_mm;
  rest.pressure_hysteresis_cbar := old.pressure_hysteresis_cbar;
  if rest is distinct from old and not public.is_gateway() then
    raise exception 'Only the gateway can change device state columns'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- Opening alerts
-- ---------------------------------------------------------------------------
-- true when gateways exist but none has synced recently
create or replace function public.all_gateways_down() returns boolean
  language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.gateways)
     and not exists (select 1 from public.gateways
                      where last_seen > now() - public.gateway_offline_after())
$$;

create or replace function public.open_alert(p_device text, p_kind text, p_message text, p_value integer)
  returns void
  language plpgsql security definer set search_path = public
as $$
declare
  quiet boolean;
begin
  quiet := exists (select 1 from public.alerts
                    where device_id = p_device and kind = p_kind
                      and resolved_at > now() - public.alert_cooldown())
           or (p_kind = 'offline' and public.all_gateways_down());

  insert into public.alerts (device_id, kind, message, value, suppressed)
  values (p_device, p_kind, p_message, p_value, quiet)
  on conflict (device_id, kind) where resolved_at is null do nothing;
end
$$;
revoke execute on function public.open_alert(text, text, text, integer) from public, anon, authenticated;

-- Thresholds with hysteresis. Between "crossed" and "back by the margin" the alert keeps
-- its current state.
create or replace function public.evaluate_telemetry_alerts() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  d public.devices;
  labels text[];
begin
  select * into d from public.devices where id = new.device_id;
  if not found then
    return new;
  end if;

  if new.level_mm is not null then
    if d.level_low_mm is not null and new.level_mm < d.level_low_mm then
      perform public.open_alert(d.id, 'level_low',
        format('Depo seviyesi düşük: %s mm (alt eşik %s mm)', new.level_mm, d.level_low_mm), new.level_mm);
    elsif d.level_low_mm is null or new.level_mm >= d.level_low_mm + d.level_hysteresis_mm then
      perform public.resolve_alert(d.id, 'level_low');
    end if;
    if d.level_high_mm is not null and new.level_mm > d.level_high_mm then
      perform public.open_alert(d.id, 'level_high',
        format('Depo seviyesi yüksek: %s mm (üst eşik %s mm)', new.level_mm, d.level_high_mm), new.level_mm);
    elsif d.level_high_mm is null or new.level_mm <= d.level_high_mm - d.level_hysteresis_mm then
      perform public.resolve_alert(d.id, 'level_high');
    end if;
  end if;

  if new.pressure_cbar is not null then
    if d.pressure_low_cbar is not null and new.pressure_cbar < d.pressure_low_cbar then
      perform public.open_alert(d.id, 'pressure_low',
        format('Basınç düşük: %s (alt eşik %s)', public.fmt_bar(new.pressure_cbar), public.fmt_bar(d.pressure_low_cbar)),
        new.pressure_cbar);
    elsif d.pressure_low_cbar is null or new.pressure_cbar >= d.pressure_low_cbar + d.pressure_hysteresis_cbar then
      perform public.resolve_alert(d.id, 'pressure_low');
    end if;
    if d.pressure_high_cbar is not null and new.pressure_cbar > d.pressure_high_cbar then
      perform public.open_alert(d.id, 'pressure_high',
        format('Basınç yüksek: %s (üst eşik %s)', public.fmt_bar(new.pressure_cbar), public.fmt_bar(d.pressure_high_cbar)),
        new.pressure_cbar);
    elsif d.pressure_high_cbar is null or new.pressure_cbar <= d.pressure_high_cbar - d.pressure_hysteresis_cbar then
      perform public.resolve_alert(d.id, 'pressure_high');
    end if;
  end if;

  -- Alarm bits as in docs/03-protokol.md (bit0 overflow, bit1 dry run, bit2 sensor fault)
  if new.alarms is not null then
    if new.alarms <> 0 then
      labels := array_remove(array[
        case when new.alarms & 1 <> 0 then 'Taşma' end,
        case when new.alarms & 2 <> 0 then 'Kuru çalışma' end,
        case when new.alarms & 4 <> 0 then 'Sensör hatası' end
      ], null);
      perform public.open_alert(d.id, 'device_alarm',
        'Cihaz alarmı: ' || coalesce(nullif(array_to_string(labels, ', '), ''), format('kod %s', new.alarms)),
        new.alarms);
    else
      perform public.resolve_alert(d.id, 'device_alarm');
    end if;
  end if;

  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- Offline checks (pg_cron, every minute), set-based
-- ---------------------------------------------------------------------------
-- Returns the number of alerts opened (devices and gateways).
create or replace function public.check_offline_devices() returns integer
  language plpgsql security definer set search_path = public
as $$
declare
  n_dev integer;
  n_gw integer;
  gw_down boolean := public.all_gateways_down();
begin
  -- Gateways first, so device alerts below see the current gateway state
  insert into public.alerts (gateway_id, kind, message, value)
  select g.id, 'gateway_offline',
         format('Gateway %s %s dakikadır bağlanmıyor', g.id,
                extract(epoch from now() - g.last_seen)::integer / 60),
         extract(epoch from now() - g.last_seen)::integer
    from public.gateways g
   where g.last_seen <= now() - public.gateway_offline_after()
  on conflict (gateway_id, kind) where resolved_at is null and gateway_id is not null do nothing;
  get diagnostics n_gw = row_count;

  update public.alerts a set resolved_at = now()
    from public.gateways g
   where a.gateway_id = g.id and a.kind = 'gateway_offline' and a.resolved_at is null
     and g.last_seen > now() - public.gateway_offline_after();

  insert into public.alerts (device_id, kind, message, value, suppressed)
  select d.id, 'offline',
         format('Cihazdan %s dakikadır veri alınamıyor', extract(epoch from now() - d.last_seen)::integer / 60),
         extract(epoch from now() - d.last_seen)::integer,
         gw_down or exists (select 1 from public.alerts p
                             where p.device_id = d.id and p.kind = 'offline'
                               and p.resolved_at > now() - public.alert_cooldown())
    from public.devices d
   where d.last_seen is not null and d.offline_after_s is not null
     and d.last_seen < now() - make_interval(secs => d.offline_after_s)
  on conflict (device_id, kind) where resolved_at is null do nothing;
  get diagnostics n_dev = row_count;

  update public.alerts a set resolved_at = now()
    from public.devices d
   where a.device_id = d.id and a.kind = 'offline' and a.resolved_at is null
     and (d.offline_after_s is null or d.last_seen >= now() - make_interval(secs => d.offline_after_s));

  return n_dev + n_gw;
end
$$;
revoke execute on function public.check_offline_devices() from public, anon, authenticated;

-- A gateway that syncs again resolves its alert at once
create or replace function public.resolve_gateway_offline_on_seen() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  if new.last_seen > now() - public.gateway_offline_after() then
    update public.alerts set resolved_at = now()
     where gateway_id = new.id and kind = 'gateway_offline' and resolved_at is null;
  end if;
  return new;
end
$$;

create trigger gateways_resolve_offline
  after insert or update of last_seen on public.gateways
  for each row execute function public.resolve_gateway_offline_on_seen();

-- ---------------------------------------------------------------------------
-- Push outbox (Edge Function send-alert-push, service role)
-- ---------------------------------------------------------------------------
-- Takes the alert for sending. Returns no row when it was already sent, is suppressed or
-- another sender holds it (claims expire after 2 minutes). Alerts that resolved in the
-- meantime are still sent: the user should know it happened.
create or replace function public.claim_alert_notification(p_id bigint)
  returns table (id bigint, kind text, message text, device_id text, gateway_id text,
                 subject_name text, created_at timestamptz)
  language sql security definer set search_path = public
as $$
  with claimed as (
    update public.alerts a
       set notify_claimed_at = now(), notify_attempts = a.notify_attempts + 1
     where a.id = p_id and a.notified_at is null and not a.suppressed
       and (a.notify_claimed_at is null or a.notify_claimed_at < now() - interval '2 minutes')
    returning a.*
  )
  select c.id, c.kind, c.message, c.device_id, c.gateway_id,
         coalesce(d.name, c.device_id, c.gateway_id), c.created_at
    from claimed c
    left join public.devices d on d.id = c.device_id
$$;

-- p_ok = true marks the alert sent; false releases the claim for the retry job.
create or replace function public.finish_alert_notification(p_id bigint, p_ok boolean, p_error text default null)
  returns void
  language sql security definer set search_path = public
as $$
  update public.alerts
     set notified_at = case when p_ok then now() end,
         notify_claimed_at = case when p_ok then notify_claimed_at end,
         notify_error = left(p_error, 500)
   where id = p_id
$$;

revoke execute on function public.claim_alert_notification(bigint) from public, anon, authenticated;
revoke execute on function public.finish_alert_notification(bigint, boolean, text) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.claim_alert_notification(bigint) to service_role;
    grant execute on function public.finish_alert_notification(bigint, boolean, text) to service_role;
  end if;
end
$$;

-- Alerts whose push is due again: unsent, not suppressed, younger than 30 minutes,
-- older than 1 minute (the webhook had its chance), at most 5 attempts, not claimed now.
create or replace view private.alerts_to_retry as
select a.id
  from public.alerts a
 where a.notified_at is null and not a.suppressed
   and a.created_at > now() - interval '30 minutes'
   and a.created_at < now() - interval '1 minute'
   and a.notify_attempts < 5
   and (a.notify_claimed_at is null or a.notify_claimed_at < now() - interval '2 minutes');

-- Calls the Edge Function again for each due alert (pg_net, asynchronous).
-- Returns the number of requests queued; 0 without pg_net or settings.
create or replace function public.retry_alert_notifications() returns integer
  language plpgsql security definer set search_path = public
as $$
declare
  url text := (select value from private.settings where key = 'push_function_url');
  secret text := (select value from private.settings where key = 'push_webhook_secret');
  r record;
  n integer := 0;
begin
  if url is null or secret is null
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    return 0;
  end if;
  for r in select id from private.alerts_to_retry order by id limit 50 loop
    execute 'select net.http_post(url := $1, body := $2, headers := $3)'
      using url,
            jsonb_build_object('type', 'INSERT', 'table', 'alerts', 'schema', 'public',
                               'record', jsonb_build_object('id', r.id)),
            jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', secret);
    n := n + 1;
  end loop;
  return n;
end
$$;
revoke execute on function public.retry_alert_notifications() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('retry-alert-notifications', '* * * * *',
                          'select public.retry_alert_notifications()');
  else
    raise notice 'pg_cron not available: schedule public.retry_alert_notifications() another way';
  end if;
exception when others then
  raise notice 'pg_cron setup skipped: %', sqlerrm;
end
$$;
