-- LoRa Water Management System - telemetry freshness and address-based ingest
--
-- Fixes and additions on top of 20261101000200_telemetry_ingest.sql:
--   * devices.last_telemetry_at - time of the newest measurement. "Late" rows are decided
--     against this column, not last_seen: a heartbeat moves last_seen forward and used to
--     mark the next (slightly older) measurement as late, so it never reached the
--     device state or the alarm checks.
--   * telemetry.ingested_at     - when the row reached the database (received_at stays the
--     measurement time, which the gateway sends as measured_at)
--   * ingest_telemetry() rows may name the device by LoRa "address" instead of
--     "device_id", so the gateway does not need its own copy of the device list.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.devices add column last_telemetry_at timestamptz;
comment on column public.devices.last_telemetry_at is
  'received_at of the newest non-late telemetry row; telemetry older than this is late';

-- Best estimate for existing devices
update public.devices d
   set last_telemetry_at = (select max(t.received_at) from public.telemetry t where t.device_id = d.id);

alter table public.telemetry add column ingested_at timestamptz not null default now();
comment on column public.telemetry.received_at is 'measurement time (gateway clock, clamped to now)';
comment on column public.telemetry.ingested_at is 'time the row reached the database';

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
create or replace function public.prepare_telemetry() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  -- A gateway clock in the future must not move last_seen ahead of real time
  if new.received_at > now() then
    new.received_at := now();
  end if;
  new.ingested_at := now();

  new.late := exists (
    select 1 from public.devices d
     where d.id = new.device_id and d.last_telemetry_at > new.received_at
  );
  return new;
end
$$;

-- Same as before, plus last_telemetry_at. last_seen only moves forward, because a
-- heartbeat may already have set it later than this measurement.
create or replace function public.apply_telemetry() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  update public.devices set
    level_mm          = coalesce(new.level_mm, level_mm),
    valve             = coalesce(new.valve, valve),
    pressure_cbar     = coalesce(new.pressure_cbar, pressure_cbar),
    flow_dl_min       = coalesce(new.flow_dl_min, flow_dl_min),
    alarms            = coalesce(new.alarms, alarms),
    last_telemetry_at = new.received_at,
    last_seen         = greatest(last_seen, new.received_at)
  where id = new.device_id;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- Gateway entry point: rows by device_id or by LoRa address
-- ---------------------------------------------------------------------------
-- p_rows: JSON array (at most 100) of
--   { "device_id": "node-1001" | "address": 4097,
--     "measured_at": "2026-11-01T10:00:00Z",                  -- optional, default now
--     "level_mm": 1250, "valve": 1, "pressure_cbar": 230, "flow_dl_min": 45, "alarms": 0,
--     "ingest_key": "gw-1:3f9a01c2:57" }                      -- optional
-- device_id wins when both are given. Rows for unknown devices or older than 7 days
-- are skipped, rows with a known ingest_key are ignored.
-- Returns {"inserted", "duplicates", "skipped"}.
create or replace function public.ingest_telemetry(p_rows jsonb)
  returns jsonb
  language plpgsql security invoker set search_path = public
as $$
declare
  total integer;
  valid integer;
  inserted integer;
begin
  if not public.is_gateway() then
    raise exception 'Only the gateway can ingest telemetry' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array' using errcode = 'invalid_parameter_value';
  end if;
  total := jsonb_array_length(p_rows);
  if total > 100 then
    raise exception 'At most 100 rows per call' using errcode = 'invalid_parameter_value';
  end if;

  -- Oldest first, so the newest row of the batch ends up as the device's state
  with src as (
    select d.id as device_id, least(coalesce(x.measured_at, now()), now()) as received_at,
           x.level_mm, x.valve, x.pressure_cbar, x.flow_dl_min, x.alarms, x.ingest_key
      from jsonb_to_recordset(p_rows) as x(
             device_id text, address integer, measured_at timestamptz, level_mm integer,
             valve smallint, pressure_cbar integer, flow_dl_min integer, alarms smallint,
             ingest_key text)
      join public.devices d
        on d.id = x.device_id or (x.device_id is null and d.address = x.address)
     where x.measured_at is null or x.measured_at > now() - interval '7 days'
  ), ins as (
    insert into public.telemetry
           (device_id, received_at, level_mm, valve, pressure_cbar, flow_dl_min, alarms, ingest_key)
    select device_id, received_at, level_mm, valve, pressure_cbar, flow_dl_min, alarms, ingest_key
      from src
     order by received_at
    on conflict (ingest_key) where ingest_key is not null do nothing
    returning 1
  )
  select (select count(*) from src), (select count(*) from ins) into valid, inserted;

  return jsonb_build_object(
    'inserted', inserted,
    'duplicates', valid - inserted,
    'skipped', total - valid
  );
end
$$;
