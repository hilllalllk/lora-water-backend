-- Tests for the command lifecycle, telemetry ingest and read models
-- (20261101000000 .. 20261101000300). Run with: backend/supabase/tests/run.sh
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

set role authenticated;

-- ===========================================================================
-- Commands: validation
-- ===========================================================================
do $t$ begin perform pg_temp.as_operator(); end $t$;

do $t$ begin
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'PERIYOT_AYARLA', '{"seconds": 5}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'PERIYOT_AYARLA', '{"seconds": 70000}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'PERIYOT_AYARLA', '{"seconds": 12.5}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'PERIYOT_AYARLA', '{"seconds": "30"}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'PERIYOT_AYARLA', '{"seconds": 1e30}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'PERIYOT_AYARLA')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'CIHAZ_ETKIN', '{"enabled": 1}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'VANA_AC', '{"x": 1}')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'POMPA_AC')$$, array['23514']);
  perform pg_temp.expect_error($$select public.send_command('node-9999', 'VANA_AC')$$, array['23503']);
  -- Direct REST inserts go through the same validation
  perform pg_temp.expect_error($$insert into public.commands (device_id, op, args) values ('node-1001', 'PERIYOT_AYARLA', '{"seconds": 1}')$$, array['23514']);
end $t$;
\echo 'OK  invalid ops and arguments are rejected (send_command and direct insert)'

do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$ begin
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'VANA_AC')$$, array['42501']);
end $t$;
\echo 'OK  viewer cannot send commands'

-- ===========================================================================
-- Commands: send, one active per device, claim
-- ===========================================================================
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$
declare r public.commands;
begin
  r := public.send_command('node-1001', 'VANA_AC', '{}');
  perform pg_temp.assert(r.status = 'pending', 'new command is pending');
  perform pg_temp.assert(r.args is null, 'empty args normalised to null');
  perform pg_temp.assert(r.expires_at between now() + interval '119 seconds' and now() + interval '121 seconds',
                         'expires_at = now + 2 min');
end $$;
-- A user-chosen deadline is ignored
insert into public.commands (device_id, op, expires_at)
values ('node-1002', 'SIMDI_OKU', now() + interval '1 day');
do $$ begin
  perform pg_temp.assert((select expires_at < now() + interval '3 minutes' from public.commands
                           where device_id = 'node-1002'), 'user cannot extend expires_at');
end $$;
\echo 'OK  send_command creates a pending command with a server-side deadline'

do $t$ begin
  perform pg_temp.expect_error($$select public.send_command('node-1001', 'VANA_KAPAT')$$, array['23505']);
end $t$;
\echo 'OK  second unfinished command for the same device is rejected'

do $t$ begin
  perform pg_temp.expect_error($$select * from public.claim_next_command()$$, array['42501']);
end $t$;
\echo 'OK  only the gateway can claim commands'

do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare
  r record;
  n integer := 0;
begin
  for r in select * from public.claim_next_command() loop
    n := n + 1;
    perform pg_temp.assert(r.device_id = 'node-1001' and r.address = 4097 and r.op = 'VANA_AC',
                           'claims the oldest command with its LoRa address');
    perform pg_temp.assert(pg_temp.status_of(r.id) = 'sent', 'claimed command is sent');
  end loop;
  perform pg_temp.assert(n = 1, 'exactly one command claimed');

  for r in select * from public.claim_next_command() loop
    perform pg_temp.assert(r.device_id = 'node-1002', 'second claim takes the next command');
  end loop;
  perform pg_temp.assert(not exists (select 1 from public.claim_next_command()), 'queue is empty');
end $$;
\echo 'OK  claim_next_command takes one command at a time, never twice'

-- ===========================================================================
-- Commands: transitions
-- ===========================================================================
do $t$ begin
  perform pg_temp.expect_error($$update public.commands set status = 'pending' where device_id = 'node-1001'$$, array['23514']);
  perform pg_temp.expect_error($$update public.commands set op = 'VANA_KAPAT' where device_id = 'node-1001'$$, array['42501']);
end $t$;
update public.commands set status = 'sent' where device_id = 'node-1001';  -- retried PATCH: no-op
update public.commands set status = 'delivered' where device_id = 'node-1001';
update public.commands set status = 'done', result = 0 where device_id = 'node-1001';
do $t$ begin
  perform pg_temp.expect_error($$update public.commands set status = 'failed' where device_id = 'node-1001'$$, array['23514']);
end $t$;
update public.commands set status = 'done', result = 0 where device_id = 'node-1002';  -- sent -> done
\echo 'OK  only valid transitions; request columns are read-only; repeats are no-ops'

-- ===========================================================================
-- Commands: expiry and stuck commands (pg_cron job)
-- ===========================================================================
reset role;
select pg_temp.as_owner() \gset
insert into public.commands (device_id, op, created_by, expires_at)
values ('node-1001', 'VANA_KAPAT', '00000000-0000-0000-0000-000000000002', now() - interval '1 second');
set role authenticated;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$ begin
  perform pg_temp.assert(not exists (select 1 from public.claim_next_command()), 'expired command is never claimed');
end $$;
reset role;
select pg_temp.as_owner() \gset
do $$ begin
  perform pg_temp.assert(public.expire_commands() = 1, 'expire_commands closes one command');
  perform pg_temp.assert((select status from public.commands where op = 'VANA_KAPAT') = 'expired', 'status is expired');
end $$;

-- A command stuck in 'sent' (gateway restarted) is failed with Timeout
insert into public.commands (device_id, op, created_by) values ('node-1003', 'SIMDI_OKU', '00000000-0000-0000-0000-000000000002');
update public.commands set status = 'sent' where device_id = 'node-1003' and status = 'pending';
set session_replication_role = replica;  -- skip touch_updated_at to fake an old update
update public.commands set updated_at = now() - interval '10 minutes' where device_id = 'node-1003' and status = 'sent';
set session_replication_role = origin;
do $$ begin
  perform pg_temp.assert(public.expire_commands() = 1, 'expire_commands fails one stuck command');
  perform pg_temp.assert((select status::text || '/' || result from public.commands
                           where device_id = 'node-1003' and op = 'SIMDI_OKU') = 'failed/3', 'failed with Timeout (3)');
end $$;
set role authenticated;
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $t$ begin perform pg_temp.expect_error($$select public.expire_commands()$$, array['42501']); end $t$;
\echo 'OK  expired commands never run; stuck commands fail with Timeout; users cannot run the job'

-- ===========================================================================
-- Commands: PERIYOT_AYARLA applies the new period
-- ===========================================================================
do $$ begin perform public.send_command('node-1003', 'PERIYOT_AYARLA', '{"seconds": 30}'); end $$;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$ begin perform public.claim_next_command(); end $$;
update public.commands set status = 'done', result = 0 where op = 'PERIYOT_AYARLA';
do $$ begin
  perform pg_temp.assert((select period_s from public.devices where id = 'node-1003') = 30, 'period_s updated');
end $$;
\echo 'OK  PERIYOT_AYARLA updates period_s when done'

-- ===========================================================================
-- Telemetry ingest
-- ===========================================================================
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$ begin perform pg_temp.expect_error($$select public.ingest_telemetry('[]')$$, array['42501']); end $t$;
\echo 'OK  only the gateway can ingest'

do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare res jsonb;
begin
  res := public.ingest_telemetry(jsonb_build_array(
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 1000, 'ingest_key', 'gw:1:1',
                       'measured_at', now() - interval '2 minutes'),
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 1100, 'ingest_key', 'gw:1:2',
                       'measured_at', now() - interval '1 minute'),
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 1100, 'ingest_key', 'gw:1:2'),  -- same key in batch
    jsonb_build_object('device_id', 'node-9999', 'level_mm', 1),                               -- unknown device
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 1, 'measured_at', now() - interval '30 days')
  ));
  perform pg_temp.assert(res = '{"inserted": 2, "duplicates": 1, "skipped": 2}', 'first batch: ' || res::text);

  res := public.ingest_telemetry(jsonb_build_array(
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 1000, 'ingest_key', 'gw:1:1')));
  perform pg_temp.assert(res = '{"inserted": 0, "duplicates": 1, "skipped": 0}', 'resent batch: ' || res::text);

  perform pg_temp.assert((select level_mm from public.devices where id = 'node-1002') = 1100,
                         'newest row of the batch is the device state');
end $$;
\echo 'OK  ingest is batched and idempotent; unknown and too-old rows are skipped'

do $$
declare res jsonb;
begin
  -- A buffered row from 10 minutes ago, below the low threshold (300 mm)
  res := public.ingest_telemetry(jsonb_build_array(
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 50, 'ingest_key', 'gw:1:3',
                       'measured_at', now() - interval '10 minutes')));
  perform pg_temp.assert((res ->> 'inserted')::int = 1, 'late row stored');
  perform pg_temp.assert((select late from public.telemetry where ingest_key = 'gw:1:3'), 'row marked late');
  perform pg_temp.assert((select level_mm from public.devices where id = 'node-1002') = 1100,
                         'late row does not overwrite the state');
  perform pg_temp.assert(not exists (select 1 from public.alerts where device_id = 'node-1002' and kind = 'level_low'),
                         'late row does not open alerts');

  -- A gateway clock in the future is clamped to now
  perform public.ingest_telemetry(jsonb_build_array(
    jsonb_build_object('device_id', 'node-1002', 'level_mm', 1200, 'measured_at', now() + interval '1 hour')));
  perform pg_temp.assert((select last_seen <= now() from public.devices where id = 'node-1002'), 'future time clamped');
end $$;
\echo 'OK  late rows go to history only; future timestamps are clamped'

-- ===========================================================================
-- Read models
-- ===========================================================================
reset role;
select pg_temp.as_owner() \gset
delete from public.telemetry;
-- 3 full hours, one row per 10 minutes: hour 0 level 100, hour 1 level 200, hour 2 level 300
insert into public.telemetry (device_id, received_at, level_mm, pressure_cbar)
select 'node-1001',
       date_trunc('hour', now()) - interval '3 hours' + (i * interval '10 minutes'),
       100 * (i / 6 + 1), 200
  from generate_series(0, 17) i;
do $$ begin
  perform pg_temp.assert(public.rollup_telemetry_hourly(now() - interval '4 hours') = 3, 'three hourly rows');
  perform pg_temp.assert((select level_sum / level_n from public.telemetry_hourly
                           where device_id = 'node-1001' order by hour limit 1) = 100, 'hourly average');
  -- Re-running is idempotent
  perform public.rollup_telemetry_hourly(now() - interval '4 hours');
  perform pg_temp.assert((select sum(samples) from public.telemetry_hourly) = 18, 'rollup is idempotent');
end $$;
\echo 'OK  hourly rollup is exact and idempotent'

set role authenticated;
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$
declare
  t0 timestamptz := date_trunc('hour', now()) - interval '3 hours';
  n integer;
begin
  -- 3 hours in 12 points -> 15 min buckets from raw rows
  select count(*) into n from public.telemetry_series('node-1001', t0, t0 + interval '3 hours', 12)
   where level_mm is not null;
  perform pg_temp.assert(n = 12, 'raw path: 12 buckets of 15 min, got ' || n);

  -- 3 hours in 1-hour buckets -> hourly path
  perform pg_temp.assert((select array_agg(level_mm order by bucket)::text
                            from public.telemetry_series('node-1001', t0, t0 + interval '10 hours', 10))
                         = '{100.0,200.0,300.0}', 'hourly path averages');

  -- 6-hour bucket merges three hours exactly: (100+200+300)/3
  perform pg_temp.assert((select level_mm from public.telemetry_series('node-1001', t0, t0 + interval '60 hours', 10))
                         = 200.0, 'merged buckets use weighted average');

  perform pg_temp.expect_error($$select * from public.telemetry_series('node-1001', now(), now() - interval '1 hour')$$,
                               array['22023']);
end $t$;
\echo 'OK  telemetry_series reads raw or hourly data and validates its input'

do $$ begin
  perform pg_temp.assert((select open_alerts from public.device_overview where id = 'node-1001') >= 0, 'overview row');
  perform pg_temp.assert((select count(*) from public.device_overview) = (select count(*) from public.devices), 'one row per device');
end $$;
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$ begin perform public.send_command('node-1001', 'SIMDI_OKU'); end $$;
do $$ begin
  perform pg_temp.assert((select active_command_op || '/' || active_command_status from public.device_overview
                           where id = 'node-1001') = 'SIMDI_OKU/pending', 'overview shows the unfinished command');
end $$;
\echo 'OK  device_overview shows alerts and the unfinished command'

\echo 'ALL TESTS PASSED (lifecycle_test)'
