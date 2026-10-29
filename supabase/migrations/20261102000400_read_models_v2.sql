-- LoRa Water Management System - read models v2, admin health, push token removal
--
--   * device_overview: explicit column list (no more d.*, which froze the view's columns
--     at creation time), plus online / gateway_online computed on the server clock
--   * alerts index for "open alerts per device"
--   * public.system_health()        - one JSON document for the admin "Sistem" screen
--   * public.unregister_push_token() - reliable token removal on sign-out

-- ---------------------------------------------------------------------------
-- Device overview
-- ---------------------------------------------------------------------------
drop view if exists public.device_overview;

create view public.device_overview
  with (security_invoker = true)
as
select d.id, d.address, d.name, d.type, d.fw, d.period_s,
       d.level_mm, d.valve, d.pressure_cbar, d.flow_dl_min, d.alarms,
       d.last_seen, d.last_telemetry_at, d.created_at,
       d.level_low_mm, d.level_high_mm, d.pressure_low_cbar, d.pressure_high_cbar,
       d.offline_after_s, d.level_hysteresis_mm, d.pressure_hysteresis_cbar,
       (d.last_seen is not null
        and d.last_seen > now() - make_interval(secs => coalesce(d.offline_after_s, 600))) as online,
       g.gateway_online,
       coalesce(a.open_alerts, 0) as open_alerts,
       c.id                       as active_command_id,
       c.op                       as active_command_op,
       c.status                   as active_command_status,
       c.created_at               as active_command_created_at
  from public.devices d
  cross join lateral (
    select exists (select 1 from public.gateways gw
                    where gw.last_seen > now() - public.gateway_offline_after()) as gateway_online
  ) g
  left join lateral (
    select count(*)::integer as open_alerts
      from public.alerts al
     where al.device_id = d.id and al.resolved_at is null
  ) a on true
  left join lateral (
    select cm.id, cm.op, cm.status, cm.created_at
      from public.commands cm
     where cm.device_id = d.id and cm.status in ('pending', 'sent', 'delivered')
     limit 1
  ) c on true;

grant select on public.device_overview to authenticated;

create index alerts_open_device_idx on public.alerts (device_id) where resolved_at is null;

-- ---------------------------------------------------------------------------
-- Admin health document
-- ---------------------------------------------------------------------------
create or replace function public.system_health() returns jsonb
  language plpgsql stable security definer set search_path = public
as $$
declare
  cron_jobs jsonb := '[]'::jsonb;
begin
  if not public.has_role('admin') then
    raise exception 'Sistem durumunu sadece yönetici görebilir' using errcode = 'insufficient_privilege';
  end if;

  -- Last run of each pg_cron job (only where pg_cron exists)
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object(
               'job', j.jobname, 'schedule', j.schedule,
               'last_status', r.status, 'last_start', r.start_time,
               'last_message', left(r.return_message, 200))
             order by j.jobname), '[]'::jsonb)
        from cron.job j
        left join lateral (
          select status, start_time, return_message from cron.job_run_details d
           where d.jobid = j.jobid order by d.start_time desc limit 1
        ) r on true
    $q$ into cron_jobs;
  end if;

  return jsonb_build_object(
    'now', now(),
    'gateways', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'fw', g.fw, 'wifi_rssi', g.wifi_rssi, 'last_seen', g.last_seen,
               'online', g.last_seen > now() - public.gateway_offline_after(),
               'heap_free', g.heap_free, 'heap_min', g.heap_min, 'uptime_s', g.uptime_s,
               'reset_reason', g.reset_reason, 'queue_len', g.queue_len, 'dropped', g.dropped,
               'last_error', g.last_error) order by g.id), '[]'::jsonb)
        from public.gateways g),
    'telemetry_24h', (
      select jsonb_build_object('rows', count(*), 'late', count(*) filter (where late),
                                'max_delay_s', coalesce(max(extract(epoch from ingested_at - received_at))::integer, 0))
        from public.telemetry where ingested_at > now() - interval '24 hours'),
    'commands_24h', (
      select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
        from (select status, count(*) as n from public.commands
               where created_at > now() - interval '24 hours' group by status) s),
    'push_24h', (
      select jsonb_build_object(
               'alerts', count(*),
               'sent', count(*) filter (where notified_at is not null),
               'suppressed', count(*) filter (where suppressed),
               'failed', count(*) filter (where notified_at is null and not suppressed and notify_attempts >= 5),
               'last_error', (array_agg(notify_error order by created_at desc)
                                filter (where notify_error is not null))[1])
        from public.alerts where created_at > now() - interval '24 hours'),
    'cron', cron_jobs
  );
end
$$;
revoke execute on function public.system_health() from public, anon;
grant execute on function public.system_health() to authenticated;

-- ---------------------------------------------------------------------------
-- Push token removal (sign-out). Deletes only the caller's own row; unknown tokens are
-- not an error, so the app can call it even when it is unsure the token was stored.
-- ---------------------------------------------------------------------------
create or replace function public.unregister_push_token(p_token text) returns void
  language sql security invoker set search_path = public
as $$
  delete from public.push_tokens where token = p_token and user_id = auth.uid()
$$;
revoke execute on function public.unregister_push_token(text) from public, anon;
grant execute on function public.unregister_push_token(text) to authenticated;
