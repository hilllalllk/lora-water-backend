-- LoRa Water Management System - user roles, alarm thresholds, alerts, push tokens
--
-- Adds on top of 20261014000000_init.sql:
--   * public.profiles with an app_role (admin / operator / viewer)
--   * only operators and admins may insert commands
--   * per-device alarm thresholds (admin only)
--   * public.alerts opened/resolved automatically from telemetry and heartbeats
--   * public.push_tokens for Expo push notifications (Edge Function send-alert-push)
--
-- First admin: after creating your own user in Authentication > Users, run in the SQL Editor:
--   update public.profiles set role = 'admin'
--    where id = (select id from auth.users where email = 'you@example.com');

-- ---------------------------------------------------------------------------
-- Roles and profiles
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('admin', 'operator', 'viewer');

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  email       text,                              -- copied from auth.users so admins can tell users apart
  role        public.app_role not null default 'viewer',
  created_at  timestamptz not null default now()
);
comment on table public.profiles is 'App users and their roles (admin, operator, viewer)';

-- Create a profile for every new auth user
create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, nullif(new.raw_user_meta_data ->> 'full_name', ''), new.email)
  on conflict (id) do nothing;
  return new;
end
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Users that existed before this migration get a (viewer) profile too
insert into public.profiles (id, full_name, email)
select u.id, nullif(u.raw_user_meta_data ->> 'full_name', ''), u.email
  from auth.users u
on conflict (id) do nothing;

-- Role of the requesting user (null for the gateway, service_role and signed-out users
-- without a profile). security definer so policies can call it without recursing into
-- profiles' own RLS.
create or replace function public.current_app_role() returns public.app_role
  language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid()
$$;

-- Usage: public.has_role('operator', 'admin')
create or replace function public.has_role(variadic roles public.app_role[]) returns boolean
  language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_app_role() = any (roles), false)
$$;

-- Guard: non-admins may only change their own full_name; nobody may remove the last admin.
-- Requests without a user (SQL Editor, service_role) are not restricted.
create or replace function public.guard_profile_update() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  allowed public.profiles;
begin
  if auth.uid() is not null and not public.has_role('admin') then
    allowed := new;
    allowed.full_name := old.full_name;
    if allowed is distinct from old then
      raise exception 'Only an admin can change roles'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if old.role = 'admin' and new.role <> 'admin'
     and not exists (select 1 from public.profiles where role = 'admin' and id <> old.id) then
    raise exception 'At least one admin must remain'
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;

create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.guard_profile_update();

alter table public.profiles enable row level security;

create policy "profiles: read" on public.profiles
  for select to authenticated using (true);
create policy "profiles: admin updates" on public.profiles
  for update to authenticated
  using (public.has_role('admin')) with check (public.has_role('admin'));
-- Own row: the guard trigger limits this to full_name
create policy "profiles: own update" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- Commands: only operators and admins may send commands
-- ---------------------------------------------------------------------------
drop policy "commands: user inserts" on public.commands;
create policy "commands: operator inserts" on public.commands
  for insert to authenticated
  with check (
    status = 'pending' and result is null and created_by = auth.uid()
    and public.has_role('operator', 'admin')
  );

-- ---------------------------------------------------------------------------
-- Alarm thresholds per device (null = no check)
-- ---------------------------------------------------------------------------
alter table public.devices
  add column level_low_mm       integer,
  add column level_high_mm      integer,
  add column pressure_low_cbar  integer,
  add column pressure_high_cbar integer,
  add column offline_after_s    integer default 600 check (offline_after_s is null or offline_after_s >= 60);

-- Admins may update devices; the guard trigger below limits them to name + thresholds.
-- The existing "devices: gateway updates" policy stays.
create policy "devices: admin updates" on public.devices
  for update to authenticated
  using (public.has_role('admin')) with check (public.has_role('admin'));

-- Guard: thresholds only by admins; every other column (except name) only by the gateway.
-- Requests without a user (SQL Editor, service_role, pg_cron) are not restricted.
create or replace function public.guard_device_update() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  rest public.devices;
begin
  if auth.uid() is null then
    return new;
  end if;

  if (new.level_low_mm, new.level_high_mm, new.pressure_low_cbar, new.pressure_high_cbar, new.offline_after_s)
     is distinct from
     (old.level_low_mm, old.level_high_mm, old.pressure_low_cbar, old.pressure_high_cbar, old.offline_after_s)
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
  if rest is distinct from old and not public.is_gateway() then
    raise exception 'Only the gateway can change device state columns'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end
$$;

create trigger devices_guard
  before update on public.devices
  for each row execute function public.guard_device_update();

-- ---------------------------------------------------------------------------
-- Alerts
-- ---------------------------------------------------------------------------
create table public.alerts (
  id           bigint generated always as identity primary key,
  device_id    text not null references public.devices(id) on delete cascade,
  kind         text not null
               check (kind in ('level_low', 'level_high', 'pressure_low', 'pressure_high', 'offline', 'device_alarm')),
  message      text not null,                     -- Turkish, shown to users and in push notifications
  value        integer,                           -- measured value (mm, cbar, alarm bits or seconds offline)
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);
comment on table public.alerts is 'Alarm events; open while resolved_at is null';
-- At most one open alert per device and kind
create unique index alerts_one_open_idx on public.alerts (device_id, kind) where resolved_at is null;
create index alerts_created_idx on public.alerts (created_at desc);

alter table public.alerts enable row level security;
-- Read-only for users; rows are written by the security definer functions below
create policy "alerts: read" on public.alerts for select to authenticated using (true);

-- Opens an alert unless one of the same kind is already open
create or replace function public.open_alert(p_device text, p_kind text, p_message text, p_value integer)
  returns void
  language sql security definer set search_path = public
as $$
  insert into public.alerts (device_id, kind, message, value)
  values (p_device, p_kind, p_message, p_value)
  on conflict (device_id, kind) where resolved_at is null do nothing
$$;

create or replace function public.resolve_alert(p_device text, p_kind text) returns void
  language sql security definer set search_path = public
as $$
  update public.alerts set resolved_at = now()
   where device_id = p_device and kind = p_kind and resolved_at is null
$$;

revoke execute on function public.open_alert(text, text, text, integer) from public, anon, authenticated;
revoke execute on function public.resolve_alert(text, text) from public, anon, authenticated;

create or replace function public.fmt_bar(cbar integer) returns text
  language sql immutable
as $$
  select replace(to_char(cbar / 100.0, 'FM990.00'), '.', ',') || ' bar'
$$;

-- Evaluates thresholds for each new telemetry row
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
    else
      perform public.resolve_alert(d.id, 'level_low');
    end if;
    if d.level_high_mm is not null and new.level_mm > d.level_high_mm then
      perform public.open_alert(d.id, 'level_high',
        format('Depo seviyesi yüksek: %s mm (üst eşik %s mm)', new.level_mm, d.level_high_mm), new.level_mm);
    else
      perform public.resolve_alert(d.id, 'level_high');
    end if;
  end if;

  if new.pressure_cbar is not null then
    if d.pressure_low_cbar is not null and new.pressure_cbar < d.pressure_low_cbar then
      perform public.open_alert(d.id, 'pressure_low',
        format('Basınç düşük: %s (alt eşik %s)', public.fmt_bar(new.pressure_cbar), public.fmt_bar(d.pressure_low_cbar)),
        new.pressure_cbar);
    else
      perform public.resolve_alert(d.id, 'pressure_low');
    end if;
    if d.pressure_high_cbar is not null and new.pressure_cbar > d.pressure_high_cbar then
      perform public.open_alert(d.id, 'pressure_high',
        format('Basınç yüksek: %s (üst eşik %s)', public.fmt_bar(new.pressure_cbar), public.fmt_bar(d.pressure_high_cbar)),
        new.pressure_cbar);
    else
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

create trigger telemetry_alerts
  after insert on public.telemetry
  for each row execute function public.evaluate_telemetry_alerts();

-- Opens 'offline' alerts for devices that have been silent longer than offline_after_s,
-- and resolves them for devices that are back. Returns the number of alerts opened.
-- Scheduled every minute with pg_cron when available (see the end of this file).
create or replace function public.check_offline_devices() returns integer
  language plpgsql security definer set search_path = public
as $$
declare
  d record;
  opened integer := 0;
  silent_s integer;
begin
  for d in
    select id, last_seen, offline_after_s from public.devices
     where last_seen is not null and offline_after_s is not null
  loop
    silent_s := extract(epoch from now() - d.last_seen)::integer;
    if silent_s > d.offline_after_s then
      if not exists (select 1 from public.alerts
                      where device_id = d.id and kind = 'offline' and resolved_at is null) then
        perform public.open_alert(d.id, 'offline',
          format('Cihazdan %s dakikadır veri alınamıyor', silent_s / 60), silent_s);
        opened := opened + 1;
      end if;
    else
      perform public.resolve_alert(d.id, 'offline');
    end if;
  end loop;
  return opened;
end
$$;
revoke execute on function public.check_offline_devices() from public, anon, authenticated;

-- Resolves the 'offline' alert as soon as the device is heard again (telemetry via
-- apply_telemetry, or a gateway heartbeat writing last_seen)
create or replace function public.resolve_offline_on_seen() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  if new.last_seen is distinct from old.last_seen and new.last_seen is not null
     and (new.offline_after_s is null
          or new.last_seen > now() - make_interval(secs => new.offline_after_s)) then
    perform public.resolve_alert(new.id, 'offline');
  end if;
  return new;
end
$$;

create trigger devices_resolve_offline
  after update of last_seen on public.devices
  for each row execute function public.resolve_offline_on_seen();

-- ---------------------------------------------------------------------------
-- Push tokens (Expo push tokens of the users' phones)
-- ---------------------------------------------------------------------------
create table public.push_tokens (
  token       text primary key,                  -- ExponentPushToken[...]
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  platform    text,                              -- 'android' | 'ios'
  updated_at  timestamptz not null default now()
);
comment on table public.push_tokens is 'Expo push tokens; read by the send-alert-push Edge Function with the service role';

alter table public.push_tokens enable row level security;
create policy "push_tokens: own read" on public.push_tokens
  for select to authenticated using (user_id = auth.uid());
create policy "push_tokens: own insert" on public.push_tokens
  for insert to authenticated with check (user_id = auth.uid());
create policy "push_tokens: own update" on public.push_tokens
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "push_tokens: own delete" on public.push_tokens
  for delete to authenticated using (user_id = auth.uid());

-- Registers the caller's token. A phone that signs in with another account keeps the
-- same token, so the row is moved to the current user (plain upsert would be blocked by RLS).
create or replace function public.register_push_token(p_token text, p_platform text default null)
  returns void
  language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in' using errcode = 'insufficient_privilege';
  end if;
  insert into public.push_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update
    set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end
$$;
revoke execute on function public.register_push_token(text, text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: the app shows alerts live
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.alerts;

-- ---------------------------------------------------------------------------
-- pg_cron: run check_offline_devices() every minute, only where the extension exists
-- (Supabase has it; a plain local PostgreSQL usually does not)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    execute $cmd$select cron.schedule('check-offline-devices', '* * * * *',
                                      'select public.check_offline_devices()')$cmd$;
  else
    raise notice 'pg_cron not available: schedule public.check_offline_devices() another way';
  end if;
exception when others then
  raise notice 'pg_cron setup skipped: %', sqlerrm;
end
$$;
