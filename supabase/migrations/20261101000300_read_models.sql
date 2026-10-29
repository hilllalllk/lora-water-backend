-- LoRa Water Management System - read models and retention
--
-- Shapes data for the app so the phone never downloads raw history:
--   * public.telemetry_hourly        - hourly sums per device (kept forever)
--   * public.rollup_telemetry_hourly - fills it (pg_cron)
--   * public.telemetry_series()      - chart series in N time buckets
--   * public.device_overview         - device + open alert count + unfinished command
--   * pg_cron jobs: hourly rollup, nightly re-rollup of late data, raw retention (90 days)

-- ---------------------------------------------------------------------------
-- Hourly rollup
-- ---------------------------------------------------------------------------
-- Sums and counts (not averages), so buckets of any size can be merged exactly.
create table public.telemetry_hourly (
  device_id      text not null references public.devices(id) on delete cascade,
  hour           timestamptz not null,
  samples        integer not null,
  level_sum      bigint,
  level_n        integer not null default 0,
  level_min      integer,
  level_max      integer,
  pressure_sum   bigint,
  pressure_n     integer not null default 0,
  pressure_min   integer,
  pressure_max   integer,
  primary key (device_id, hour)
);
comment on table public.telemetry_hourly is 'Hourly telemetry sums per device, filled by rollup_telemetry_hourly()';

alter table public.telemetry_hourly enable row level security;
create policy "telemetry_hourly: read" on public.telemetry_hourly
  for select to authenticated using (true);

-- Recomputes every hour that starts at or after date_trunc('hour', p_since).
-- Returns the number of (device, hour) rows written.
create or replace function public.rollup_telemetry_hourly(p_since timestamptz default now() - interval '3 hours')
  returns integer
  language plpgsql security definer set search_path = public
as $$
declare
  n integer;
begin
  insert into public.telemetry_hourly as h
         (device_id, hour, samples,
          level_sum, level_n, level_min, level_max,
          pressure_sum, pressure_n, pressure_min, pressure_max)
  select device_id, date_trunc('hour', received_at), count(*),
         sum(level_mm), count(level_mm), min(level_mm), max(level_mm),
         sum(pressure_cbar), count(pressure_cbar), min(pressure_cbar), max(pressure_cbar)
    from public.telemetry
   where received_at >= date_trunc('hour', p_since)
   group by 1, 2
  on conflict (device_id, hour) do update set
    samples = excluded.samples,
    level_sum = excluded.level_sum, level_n = excluded.level_n,
    level_min = excluded.level_min, level_max = excluded.level_max,
    pressure_sum = excluded.pressure_sum, pressure_n = excluded.pressure_n,
    pressure_min = excluded.pressure_min, pressure_max = excluded.pressure_max;
  get diagnostics n = row_count;
  return n;
end
$$;
revoke execute on function public.rollup_telemetry_hourly(timestamptz) from public, anon, authenticated;

-- One-time backfill of the history that exists before this migration
do $$ begin perform public.rollup_telemetry_hourly('-infinity'); end $$;

-- ---------------------------------------------------------------------------
-- Chart series
-- ---------------------------------------------------------------------------
-- Splits [p_from, p_to) into p_points equal buckets and averages each one.
-- Buckets of an hour or more are read from telemetry_hourly (cheap for 7 / 30 days),
-- shorter buckets from raw telemetry. Empty buckets are not returned; the app draws
-- them as gaps. Runs as the caller, so RLS applies.
create or replace function public.telemetry_series(
  p_device_id text,
  p_from timestamptz,
  p_to timestamptz default now(),
  p_points integer default 120
)
  returns table (bucket timestamptz, level_mm numeric, pressure_cbar numeric, samples integer)
  language plpgsql stable security invoker set search_path = public
as $$
#variable_conflict use_column
declare
  stride interval;
begin
  if p_to <= p_from or p_to - p_from > interval '400 days' then
    raise exception 'Range must be positive and at most 400 days' using errcode = 'invalid_parameter_value';
  end if;
  if p_points not between 10 and 1000 then
    raise exception 'p_points must be 10..1000' using errcode = 'invalid_parameter_value';
  end if;
  stride := (p_to - p_from) / p_points;

  if stride >= interval '1 hour' then
    return query
    select date_bin(stride, h.hour, p_from) as b,
           round(sum(h.level_sum)::numeric / nullif(sum(h.level_n), 0), 1),
           round(sum(h.pressure_sum)::numeric / nullif(sum(h.pressure_n), 0), 1),
           sum(h.samples)::integer
      from public.telemetry_hourly h
     where h.device_id = p_device_id and h.hour >= p_from and h.hour < p_to
     group by b
     order by b;
  else
    return query
    select date_bin(stride, t.received_at, p_from) as b,
           round(avg(t.level_mm), 1),
           round(avg(t.pressure_cbar), 1),
           count(*)::integer
      from public.telemetry t
     where t.device_id = p_device_id and t.received_at >= p_from and t.received_at < p_to
     group by b
     order by b;
  end if;
end
$$;
revoke execute on function public.telemetry_series(text, timestamptz, timestamptz, integer) from public, anon;
grant execute on function public.telemetry_series(text, timestamptz, timestamptz, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Device overview (one row per device for the list screen)
-- ---------------------------------------------------------------------------
-- security_invoker: the view uses the caller's RLS, not the view owner's.
-- Realtime does not stream views; the app listens to devices / alerts / commands
-- and refetches this view.
create or replace view public.device_overview
  with (security_invoker = true)
as
select d.*,
       coalesce(a.open_alerts, 0) as open_alerts,
       c.id                       as active_command_id,
       c.op                       as active_command_op,
       c.status                   as active_command_status
  from public.devices d
  left join lateral (
    select count(*)::integer as open_alerts
      from public.alerts al
     where al.device_id = d.id and al.resolved_at is null
  ) a on true
  left join lateral (
    select cm.id, cm.op, cm.status
      from public.commands cm
     where cm.device_id = d.id and cm.status in ('pending', 'sent', 'delivered')
     limit 1
  ) c on true;

grant select on public.device_overview to authenticated;

-- ---------------------------------------------------------------------------
-- Schedules
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- 5 past every hour: the last 3 hours (covers the current and late-arriving rows)
    perform cron.schedule('rollup-telemetry-hourly', '5 * * * *',
                          'select public.rollup_telemetry_hourly()');
    -- 03:00 UTC: the last 8 days, for rows the gateway buffered and sent late
    perform cron.schedule('rollup-telemetry-late', '0 3 * * *',
                          $cmd$select public.rollup_telemetry_hourly(now() - interval '8 days')$cmd$);
    -- 03:30 UTC: raw rows older than 90 days (hourly sums stay)
    perform cron.schedule('cleanup-old-telemetry', '30 3 * * *',
                          'select public.cleanup_old_telemetry(90)');
  else
    raise notice 'pg_cron not available: schedule the rollup and cleanup jobs another way';
  end if;
exception when others then
  raise notice 'pg_cron setup skipped: %', sqlerrm;
end
$$;
