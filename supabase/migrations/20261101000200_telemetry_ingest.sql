-- LoRa Water Management System - idempotent telemetry ingest
--
-- The gateway ACKs a frame before it reaches Supabase, so a failed HTTP request
-- would lose the measurement. With this migration the gateway can buffer rows and
-- resend them safely:
--   * telemetry.ingest_key  - unique per measurement; a resent row is ignored
--   * telemetry.late        - set for rows older than the device's last_seen; late rows
--                             go into history but never overwrite the current state
--                             and never open or resolve alerts
--   * public.ingest_telemetry(jsonb) - batch insert for the gateway
--
-- Suggested ingest_key format (firmware): "<gateway_id>:<boot_id>:<counter>", where
-- boot_id is a random 32-bit value chosen at start-up and counter increases per row.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.telemetry
  add column ingest_key text check (ingest_key is null or length(ingest_key) between 1 and 100),
  add column late boolean not null default false;

create unique index telemetry_ingest_key_idx on public.telemetry (ingest_key)
  where ingest_key is not null;

comment on column public.telemetry.late is
  'true when the row arrived after newer data for the device (buffered by the gateway)';

-- ---------------------------------------------------------------------------
-- Before insert: clamp the timestamp and mark late rows
-- ---------------------------------------------------------------------------
create or replace function public.prepare_telemetry() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  -- A gateway clock in the future must not move last_seen ahead of real time
  if new.received_at > now() then
    new.received_at := now();
  end if;

  new.late := exists (
    select 1 from public.devices d
     where d.id = new.device_id and d.last_seen > new.received_at
  );
  return new;
end
$$;

create trigger telemetry_prepare
  before insert on public.telemetry
  for each row execute function public.prepare_telemetry();

-- The state and alert triggers only see current rows. Their functions are unchanged.
drop trigger telemetry_apply on public.telemetry;
create trigger telemetry_apply
  after insert on public.telemetry
  for each row when (not new.late) execute function public.apply_telemetry();

drop trigger telemetry_alerts on public.telemetry;
create trigger telemetry_alerts
  after insert on public.telemetry
  for each row when (not new.late) execute function public.evaluate_telemetry_alerts();

-- ---------------------------------------------------------------------------
-- Gateway entry point
-- ---------------------------------------------------------------------------
-- p_rows: JSON array (at most 100) of
--   { "device_id": "node-1001", "measured_at": "2026-11-01T10:00:00Z",   -- optional, default now
--     "level_mm": 1250, "valve": 1, "pressure_cbar": 230, "flow_dl_min": 45, "alarms": 0,
--     "ingest_key": "gw-1:3f9a01c2:57" }                                   -- optional
-- Rows for unknown devices or older than 7 days are skipped, rows with a known
-- ingest_key are ignored. Returns {"inserted", "duplicates", "skipped"}.
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
    select x.device_id, least(coalesce(x.measured_at, now()), now()) as received_at,
           x.level_mm, x.valve, x.pressure_cbar, x.flow_dl_min, x.alarms, x.ingest_key
      from jsonb_to_recordset(p_rows) as x(
             device_id text, measured_at timestamptz, level_mm integer, valve smallint,
             pressure_cbar integer, flow_dl_min integer, alarms smallint, ingest_key text)
      join public.devices d on d.id = x.device_id
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
revoke execute on function public.ingest_telemetry(jsonb) from public, anon;
grant execute on function public.ingest_telemetry(jsonb) to authenticated;
