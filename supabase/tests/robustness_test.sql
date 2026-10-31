-- Tests for gateway sync, leased commands, alert hysteresis, push outbox and read models v2
-- (20261102000000 .. 20261102000400). Run with: backend/supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'admin@test'),
  ('00000000-0000-0000-0000-000000000002', 'operator@test'),
  ('00000000-0000-0000-0000-000000000003', 'viewer@test'),
  ('00000000-0000-0000-0000-00000000000b', 'gateway@test');
update public.profiles set role = 'admin'    where id = '00000000-0000-0000-0000-000000000001';
update public.profiles set role = 'operator' where id = '00000000-0000-0000-0000-000000000002';

\i seed.sql

create function pg_temp.as_(sub text, app_role text default null) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', sub,
      'app_metadata', case when app_role is null then '{}'::json else json_build_object('role', app_role) end)::text,
    false);
$$;
create function pg_temp.as_operator() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-000000000002') $$;
create function pg_temp.as_viewer() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-000000000003') $$;
create function pg_temp.as_gateway() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-00000000000b', 'gateway') $$;
-- Expects the statement to fail with one of the given SQLSTATEs
create function pg_temp.expect_error(sql text, states text[]) returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'UNEXPECTED: allowed -> %', sql;
exception when others then
  if sqlerrm like 'UNEXPECTED:%' then raise; end if;
  if not (sqlstate = any (states)) then
    raise exception 'expected % but got % (%) -> %', states, sqlstate, sqlerrm, sql;
  end if;
end $$;
create function pg_temp.assert(ok boolean, msg text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if;
end $$;
-- Database owner context (SQL Editor, pg_cron): no role switch and no JWT
create function pg_temp.as_owner() returns void language sql as
  $$ select set_config('request.jwt.claims', '', false) $$;
create function pg_temp.status_of(cmd bigint) returns text language sql as
  $$ select status::text from public.commands where id = cmd $$;
create function pg_temp.as_admin() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-000000000001') $$;
create function pg_temp.open_alerts(dev text, k text) returns bigint language sql as
  $$ select count(*) from public.alerts where device_id = dev and kind = k and resolved_at is null $$;

set role authenticated;

-- ===========================================================================
-- Telemetry freshness: a heartbeat does not make the next measurement late
-- ===========================================================================
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare res jsonb;
begin
  perform public.mark_devices_seen('[{"address": 4097, "fw": "1.2.0"}]');
  res := public.ingest_telemetry(jsonb_build_array(jsonb_build_object(
    'address', 4097, 'measured_at', now() - interval '5 seconds', 'level_mm', 1111, 'ingest_key', 'gw-1:a:1')));
  perform pg_temp.assert(res ->> 'inserted' = '1', 'row by address inserted: ' || res::text);
  perform pg_temp.assert(not (select late from public.telemetry where ingest_key = 'gw-1:a:1'), 'not late after heartbeat');
  perform pg_temp.assert((select level_mm from public.devices where id = 'node-1001') = 1111, 'device state updated');
  perform pg_temp.assert((select fw from public.devices where id = 'node-1001') = '1.2.0', 'heartbeat fw stored');
  perform pg_temp.assert((select last_seen from public.devices where id = 'node-1001') = now(), 'last_seen not moved back');

  -- Older than the newest measurement: history only
  res := public.ingest_telemetry(jsonb_build_array(jsonb_build_object(
    'address', 4097, 'measured_at', now() - interval '1 minute', 'level_mm', 5, 'ingest_key', 'gw-1:a:0')));
  perform pg_temp.assert((select late from public.telemetry where ingest_key = 'gw-1:a:0'), 'older row is late');
  perform pg_temp.assert((select level_mm from public.devices where id = 'node-1001') = 1111, 'late row ignored for state');

  -- Unknown address is skipped
  res := public.ingest_telemetry('[{"address": 9999, "level_mm": 1}]');
  perform pg_temp.assert(res ->> 'skipped' = '1', 'unknown address skipped');
end $$;
\echo 'OK  heartbeat does not mark telemetry late; ingest by LoRa address'

-- ===========================================================================
-- send_command is idempotent with a client request id
-- ===========================================================================
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$
declare a public.commands; b public.commands;
begin
  a := public.send_command('node-1001', 'VANA_AC', null, '11111111-1111-1111-1111-111111111111');
  b := public.send_command('node-1001', 'VANA_AC', null, '11111111-1111-1111-1111-111111111111');
  perform pg_temp.assert(a.id = b.id, 'retry returns the same command');
  perform pg_temp.assert((select count(*) from public.commands where device_id = 'node-1001') = 1, 'one row');
  perform pg_temp.expect_error($q$select public.send_command('node-1001', 'VANA_KAPAT', null, '22222222-2222-2222-2222-222222222222')$q$,
                               array['23505']);
end $$;
\echo 'OK  send_command with the same client_request_id returns the first command'

-- ===========================================================================
-- Leases: a lost response only costs the lease time
-- ===========================================================================
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare r record; id1 bigint;
begin
  select * into r from public.lease_next_command('gw-1');
  id1 := r.id;
  perform pg_temp.assert(r.address = 4097 and r.op = 'VANA_AC', 'leased the command');
  perform pg_temp.assert(pg_temp.status_of(id1) = 'pending', 'leased command stays pending');
  perform pg_temp.assert(not exists (select 1 from public.lease_next_command('gw-1')), 'lease is exclusive');
end $$;
-- The response was "lost": the lease runs out
reset role;
select pg_temp.as_owner() \gset
update public.commands set lease_until = now() - interval '1 second' where device_id = 'node-1001';
set role authenticated;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare r record;
begin
  select * into r from public.lease_next_command('gw-1');
  perform pg_temp.assert(r.op = 'VANA_AC', 'leased again after the lease ran out');
  perform pg_temp.assert((select attempts from public.commands where id = r.id) = 2, 'attempts counted');

  perform pg_temp.assert(public.report_command(r.id, 'sent') = 'ok', 'sent');
  perform pg_temp.assert(public.report_command(r.id, 'sent') = 'noop', 'repeated sent is a no-op');
  perform pg_temp.assert(public.report_command(r.id, 'delivered') = 'ok', 'delivered');
  perform pg_temp.assert(public.report_command(r.id, 'done', 0::smallint) = 'ok', 'done');
  perform pg_temp.assert(public.report_command(r.id, 'delivered') = 'noop', 'late ACK report after done is a no-op');
  perform pg_temp.assert(public.report_command(r.id, 'failed', 3::smallint) = 'rejected', 'done cannot become failed');
  perform pg_temp.assert(public.report_command(999999, 'done') = 'unknown', 'unknown command');
  perform pg_temp.assert(pg_temp.status_of(r.id) = 'done', 'final status done');
end $$;
\echo 'OK  leased claims are retried after a lost response; reports are idempotent'

-- A late CMD_RESULT corrects a Timeout
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$ begin perform public.send_command('node-1002', 'VANA_KAPAT'); end $$;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare r record;
begin
  select * into r from public.lease_next_command('gw-1');
  perform public.report_command(r.id, 'sent');
  perform public.report_command(r.id, 'failed', 3::smallint);
  perform pg_temp.assert(public.report_command(r.id, 'done', 0::smallint) = 'ok', 'Timeout corrected to done');
  perform pg_temp.assert(pg_temp.status_of(r.id) = 'done', 'status done after correction');
end $$;
\echo 'OK  a late CMD_RESULT corrects a Timeout failure'

-- The expiry job leaves a leased command alone; a leased command that expired can still be reported
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$ begin perform public.send_command('node-1003', 'SIMDI_OKU'); end $$;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$ begin perform public.lease_next_command('gw-1'); end $$;
reset role;
select pg_temp.as_owner() \gset
update public.commands set expires_at = now() - interval '1 second' where device_id = 'node-1003' and status = 'pending';
do $$ begin
  perform pg_temp.assert(public.expire_commands() = 0, 'leased command is not expired');
end $$;
update public.commands set lease_until = now() - interval '1 second' where device_id = 'node-1003' and status = 'pending';
do $$ begin
  perform pg_temp.assert(public.expire_commands() = 1, 'expires once the lease is over');
end $$;
set role authenticated;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$ begin
  perform pg_temp.assert(public.report_command((select id from public.commands where device_id = 'node-1003'),
                                               'sent') = 'ok', 'transmitted just before expiry: reported');
end $$;
\echo 'OK  expiry respects leases; a transmitted command is never lost as expired'

-- ===========================================================================
-- gateway_sync: one call, parts fail independently
-- ===========================================================================
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$ begin perform public.send_command('node-1001', 'SIMDI_OKU'); end $$;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare res jsonb;
begin
  res := public.gateway_sync(jsonb_build_object(
    'gateway_id', 'gw-1',
    'telemetry', jsonb_build_array(jsonb_build_object('address', 4098, 'level_mm', 900, 'ingest_key', 'gw-1:b:1')),
    'seen', '[{"address": 4099, "fw": "2.0.0"}]'::jsonb,
    'reports', '[{"id": 999999, "status": "done"}, {"id": 1, "status": "bogus"}]'::jsonb,
    'health', '{"fw": "3.0.0", "wifi_rssi": -60, "heap_free": 90000, "queue_len": 0}'::jsonb));
  perform pg_temp.assert(res -> 'ingest' ->> 'inserted' = '1', 'telemetry ingested: ' || res::text);
  perform pg_temp.assert(res -> 'command' ->> 'op' = 'SIMDI_OKU' and (res -> 'command' ->> 'address')::int = 4097,
                         'command leased: ' || res::text);
  perform pg_temp.assert(res -> 'reports' -> 0 ->> 'outcome' = 'unknown', 'unknown report');
  perform pg_temp.assert(res -> 'reports' -> 1 ->> 'outcome' = 'rejected', 'bad report rejected');
  perform pg_temp.assert(jsonb_array_length(res -> 'errors') = 1, 'one error listed: ' || res::text);
  perform pg_temp.assert((select fw from public.devices where id = 'node-1003') = '2.0.0', 'seen applied');
  perform pg_temp.assert((select heap_free from public.gateways where id = 'gw-1') = 90000, 'health stored');
  perform pg_temp.assert((res ->> 'poll_ms')::int = 1000, 'fast poll while a command was handed out');

  res := public.gateway_sync('{"gateway_id": "gw-1", "telemetry": "oops", "claim": false}');
  perform pg_temp.assert(res -> 'command' = 'null'::jsonb and (res ->> 'poll_ms')::int = 3000, 'idle: slow poll ' || res::text);

  perform pg_temp.expect_error($q$select public.gateway_sync('{}')$q$, array['22023']);
end $$;
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $t$ begin perform pg_temp.expect_error($q$select public.gateway_sync('{"gateway_id": "x"}')$q$, array['42501']); end $t$;
\echo 'OK  gateway_sync applies each part on its own and hands out the next command'

-- ===========================================================================
-- Alerts: hysteresis and re-open cooldown (node-1002: high 1800, hysteresis 20)
-- ===========================================================================
do $t$ begin perform pg_temp.as_gateway(); end $t$;
insert into public.telemetry (device_id, level_mm) values ('node-1002', 1850);
insert into public.telemetry (device_id, level_mm) values ('node-1002', 1790);  -- inside the margin
do $$ begin
  perform pg_temp.assert(pg_temp.open_alerts('node-1002', 'level_high') = 1, 'still open inside the margin');
end $$;
insert into public.telemetry (device_id, level_mm) values ('node-1002', 1801);
insert into public.telemetry (device_id, level_mm) values ('node-1002', 1790);
insert into public.telemetry (device_id, level_mm) values ('node-1002', 1770);  -- back by the margin
do $$ begin
  perform pg_temp.assert(pg_temp.open_alerts('node-1002', 'level_high') = 0, 'resolved after the margin');
  perform pg_temp.assert((select count(*) from public.alerts where device_id = 'node-1002' and kind = 'level_high') = 1,
                         'hovering opened one alert, not many');
end $$;
insert into public.telemetry (device_id, level_mm) values ('node-1002', 1850);
do $$ begin
  perform pg_temp.assert((select suppressed from public.alerts where device_id = 'node-1002' and kind = 'level_high'
                           and resolved_at is null), 're-open within the cooldown is suppressed');
end $$;
\echo 'OK  hysteresis prevents alert storms; quick re-opens are not pushed again'

-- ===========================================================================
-- Gateway offline: one alert, device offline alerts suppressed
-- ===========================================================================
reset role;
select pg_temp.as_owner() \gset
update public.gateways set last_seen = now() - interval '10 minutes';
update public.devices set last_seen = now() - interval '20 minutes' where id = 'node-1003';
do $$ begin
  perform pg_temp.assert(public.check_offline_devices() = 2, 'gateway + device alert opened');
  perform pg_temp.assert((select count(*) from public.alerts where gateway_id = 'gw-1' and kind = 'gateway_offline'
                           and resolved_at is null) = 1, 'gateway_offline open');
  perform pg_temp.assert((select suppressed from public.alerts where device_id = 'node-1003' and kind = 'offline'),
                         'device offline suppressed while the gateway is down');
  perform pg_temp.assert(public.check_offline_devices() = 0, 'no duplicates');
end $$;
set role authenticated;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$ begin perform public.gateway_sync('{"gateway_id": "gw-1", "claim": false}'); end $$;
do $$ begin
  perform pg_temp.assert(not exists (select 1 from public.alerts where gateway_id = 'gw-1' and resolved_at is null),
                         'gateway alert resolved by the next sync');
end $$;
\echo 'OK  gateway outage: one gateway alert, device alerts suppressed'

-- ===========================================================================
-- Push outbox
-- ===========================================================================
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $t$ begin perform pg_temp.expect_error($q$select * from public.claim_alert_notification(1)$q$, array['42501']); end $t$;
reset role;
select pg_temp.as_owner() \gset
do $$
declare
  a bigint := (select id from public.alerts where gateway_id = 'gw-1' limit 1);
  s bigint := (select id from public.alerts where device_id = 'node-1003' and kind = 'offline');
  r record;
begin
  select * into r from public.claim_alert_notification(a);
  perform pg_temp.assert(r.subject_name = 'gw-1' and r.kind = 'gateway_offline', 'claimed gateway alert');
  perform pg_temp.assert(not exists (select 1 from public.claim_alert_notification(a)), 'claim is exclusive');
  perform public.finish_alert_notification(a, false, 'Expo 503');
  perform pg_temp.assert(exists (select 1 from public.claim_alert_notification(a)), 'released claim can be retried');
  perform public.finish_alert_notification(a, true);
  perform pg_temp.assert(not exists (select 1 from public.claim_alert_notification(a)), 'sent alert is never sent again');
  perform pg_temp.assert((select notify_attempts from public.alerts where id = a) = 2, 'attempts counted');
  perform pg_temp.assert(not exists (select 1 from public.claim_alert_notification(s)), 'suppressed alert is not sent');
  perform pg_temp.assert(public.retry_alert_notifications() = 0, 'retry job is a no-op without pg_net settings');
end $$;
\echo 'OK  push outbox: exclusive claims, retries, suppressed alerts skipped'

-- ===========================================================================
-- Read models v2, system health, push token removal
-- ===========================================================================
set role authenticated;
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $$ begin
  perform pg_temp.assert((select online from public.device_overview where id = 'node-1001'), 'node-1001 online');
  perform pg_temp.assert(not (select online from public.device_overview where id = 'node-1003'), 'node-1003 offline');
  perform pg_temp.assert((select bool_and(gateway_online) from public.device_overview), 'gateway online');
  perform pg_temp.expect_error($q$select public.system_health()$q$, array['42501']);
  perform public.register_push_token('ExponentPushToken[viewer]', 'android');
  perform public.unregister_push_token('ExponentPushToken[viewer]');
  perform public.unregister_push_token('ExponentPushToken[never-stored]');
  perform pg_temp.assert(not exists (select 1 from public.push_tokens), 'token removed');
end $$;
do $t$ begin perform pg_temp.as_admin(); end $t$;
do $$
declare h jsonb := public.system_health();
begin
  perform pg_temp.assert(h -> 'gateways' -> 0 ->> 'id' = 'gw-1', 'health lists the gateway: ' || h::text);
  perform pg_temp.assert((h -> 'telemetry_24h' ->> 'rows')::int > 0, 'health counts telemetry');
  perform pg_temp.assert((h -> 'push_24h' ->> 'sent')::int = 1, 'health counts sent pushes');
end $$;
\echo 'OK  device_overview online flags, admin-only system_health, unregister_push_token'

-- The app listens to exactly these tables (mobile/src/lib/realtime.ts REALTIME_TABLES).
-- A table missing from the publication silently drops every subscription of the channel.
do $$ begin
  perform pg_temp.assert((select array_agg(tablename::text order by tablename) from pg_publication_tables
                           where pubname = 'supabase_realtime' and schemaname = 'public')
                         = array['alerts', 'commands', 'devices'], 'realtime publication = app channel tables');
end $$;
\echo 'OK  realtime publication matches the app channel'

\echo 'ALL TESTS PASSED (robustness_test)'
