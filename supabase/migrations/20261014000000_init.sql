-- LoRa Water Management System - initial schema
-- Design: docs/02-sistem-mimarisi.md §6
--
-- Setup: paste into the Supabase dashboard SQL Editor and run,
-- or with the Supabase CLI: supabase db push

-- ---------------------------------------------------------------------------
-- Helper: is the requesting user the gateway?
-- The gateway user has {"role": "gateway"} in its app_metadata.
-- Only an admin (service_role) can change app_metadata.
-- ---------------------------------------------------------------------------
create or replace function public.is_gateway() returns boolean
  language sql stable
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'gateway', false)
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Devices and their latest state
create table public.devices (
  id            text primary key,                              -- e.g. 'node-1001'
  address       integer not null unique
                check (address between 2 and 65534),           -- LoRa address (0x0001 gateway, 0xFFFF broadcast)
  name          text not null,
  type          text not null default 'tank+valve',
  fw            text,
  period_s      integer not null default 60 check (period_s >= 10),
  level_mm      integer,
  valve         smallint check (valve between 0 and 3),        -- 0 closed, 1 open, 2 moving, 3 fault
  pressure_cbar integer,
  flow_dl_min   integer,
  alarms        smallint not null default 0,
  last_seen     timestamptz,
  created_at    timestamptz not null default now()
);
comment on table public.devices is 'Field nodes and their last known state';

-- Measurement history (one row per TELEMETRY / CMD_RESULT)
create table public.telemetry (
  id            bigint generated always as identity primary key,
  device_id     text not null references public.devices(id) on delete cascade,
  received_at   timestamptz not null default now(),
  level_mm      integer,
  valve         smallint,
  pressure_cbar integer,
  flow_dl_min   integer,
  alarms        smallint
);
create index telemetry_device_time_idx on public.telemetry (device_id, received_at desc);
comment on table public.telemetry is 'Measurement history inserted by the gateway';

-- Command queue
create type public.command_status as enum ('pending', 'sent', 'delivered', 'done', 'failed');

create table public.commands (
  id          bigint generated always as identity primary key,  -- on LoRa, cmdId = id & 0xFFFF
  device_id   text not null references public.devices(id) on delete cascade,
  op          text not null
              check (op in ('VANA_AC', 'VANA_KAPAT', 'CIHAZ_ETKIN', 'SIMDI_OKU', 'PERIYOT_AYARLA')),
  args        jsonb,
  status      public.command_status not null default 'pending',
  result      smallint,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index commands_pending_idx on public.commands (id) where status = 'pending';
comment on table public.commands is 'Commands sent from the mobile app to the field';

-- Gateway health (ESP32 gateway, reports Wi-Fi signal strength).
-- wifi_rssi is optional and may stay null.
create table public.gateways (
  id         text primary key,
  fw         text,
  wifi_rssi  integer,
  last_seen  timestamptz
);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- On new telemetry, update the device's latest state
create or replace function public.apply_telemetry() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  update public.devices set
    level_mm      = coalesce(new.level_mm, level_mm),
    valve         = coalesce(new.valve, valve),
    pressure_cbar = coalesce(new.pressure_cbar, pressure_cbar),
    flow_dl_min   = coalesce(new.flow_dl_min, flow_dl_min),
    alarms        = coalesce(new.alarms, alarms),
    last_seen     = new.received_at
  where id = new.device_id;
  return new;
end
$$;

create trigger telemetry_apply
  after insert on public.telemetry
  for each row execute function public.apply_telemetry();

-- Keep commands.updated_at current
create or replace function public.touch_updated_at() returns trigger
  language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end
$$;

create trigger commands_touch
  before update on public.commands
  for each row execute function public.touch_updated_at();

-- When PERIYOT_AYARLA completes successfully, update devices.period_s
create or replace function public.apply_period_command() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  if new.op = 'PERIYOT_AYARLA' and new.status = 'done' and old.status is distinct from 'done' then
    update public.devices
       set period_s = (new.args ->> 'seconds')::integer
     where id = new.device_id;
  end if;
  return new;
end
$$;

create trigger commands_apply_period
  after update on public.commands
  for each row execute function public.apply_period_command();

-- ---------------------------------------------------------------------------
-- Row level security (RLS)
-- ---------------------------------------------------------------------------
alter table public.devices   enable row level security;
alter table public.telemetry enable row level security;
alter table public.commands  enable row level security;
alter table public.gateways  enable row level security;

-- Read: any signed-in user
create policy "devices: read"   on public.devices   for select to authenticated using (true);
create policy "telemetry: read" on public.telemetry for select to authenticated using (true);
create policy "commands: read"  on public.commands  for select to authenticated using (true);
create policy "gateways: read"  on public.gateways  for select to authenticated using (true);

-- devices: insert/delete only from the dashboard (service_role). The gateway updates rows for heartbeats.
create policy "devices: gateway updates" on public.devices
  for update to authenticated using (public.is_gateway()) with check (public.is_gateway());

-- telemetry: only the gateway inserts; nobody updates
create policy "telemetry: gateway inserts" on public.telemetry
  for insert to authenticated with check (public.is_gateway());

-- commands: users insert only 'pending' commands; only the gateway changes status.
-- The ESP32 gateway polls pending commands over REST every 1-2 s.
create policy "commands: user inserts" on public.commands
  for insert to authenticated
  with check (status = 'pending' and result is null and created_by = auth.uid());
create policy "commands: gateway updates" on public.commands
  for update to authenticated using (public.is_gateway()) with check (public.is_gateway());

-- gateways: only the gateway inserts/updates its own row
create policy "gateways: gateway inserts" on public.gateways
  for insert to authenticated with check (public.is_gateway());
create policy "gateways: gateway updates" on public.gateways
  for update to authenticated using (public.is_gateway()) with check (public.is_gateway());

-- ---------------------------------------------------------------------------
-- Realtime: the mobile app receives live changes to these tables;
-- the gateway subscribes to commands inserts
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.devices, public.commands;

-- ---------------------------------------------------------------------------
-- Maintenance: delete old telemetry (free plan has a 500 MB limit)
-- Example: select public.cleanup_old_telemetry(90);
-- ---------------------------------------------------------------------------
create or replace function public.cleanup_old_telemetry(keep_days integer default 90)
  returns bigint
  language sql security definer set search_path = public
as $$
  with deleted as (
    delete from public.telemetry
     where received_at < now() - make_interval(days => keep_days)
    returning 1
  )
  select count(*) from deleted
$$;
revoke execute on function public.cleanup_old_telemetry(integer) from public, anon, authenticated;
