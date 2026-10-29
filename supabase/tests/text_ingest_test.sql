-- Tests for text protocol ingest (20261103000000_text_ingest.sql, ADR-0011).
-- Run with: backend/supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'admin@test'),
  ('00000000-0000-0000-0000-000000000002', 'operator@test'),
  ('00000000-0000-0000-0000-000000000003', 'viewer@test'),
  ('00000000-0000-0000-0000-00000000000b', 'gateway@test');
update auth.users set raw_app_meta_data = '{"role": "gateway"}' where id = '00000000-0000-0000-0000-00000000000b';
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
-- Tokens: issued from the SQL Editor only, stored as a hash
-- ===========================================================================
reset role;
select pg_temp.as_owner() \gset
select set_config('test.token', public.issue_ingest_token('gw-text-01', 'test'), false) \gset
select set_config('test.old_token', public.issue_ingest_token('gw-text-01', 'old'), false) \gset
update public.ingest_tokens set revoked_at = now() where label = 'old';
do $$ begin
  perform pg_temp.assert(current_setting('test.token') ~ '^lwm_[0-9a-f]{64}$', 'token format');
  perform pg_temp.assert(not exists (select 1 from public.ingest_tokens where token_hash = current_setting('test.token')), 'plain token not stored');
  perform pg_temp.assert((select protocol from public.devices where id = 'depo-01') = 'text', 'seed text device');
end $$;

set role authenticated;
do $t$ begin perform pg_temp.as_admin(); end $t$;
do $$ begin
  perform pg_temp.assert(not exists (select 1 from public.ingest_tokens), 'admin cannot read tokens');
  perform pg_temp.expect_error($q$select public.issue_ingest_token('x')$q$, array['42501']);
  perform pg_temp.expect_error($q$select public.ingest_tank_reading('t', 'DEPO_01', 50, 'ACIK')$q$, array['42501']);
end $$;
reset role;
set role anon;
do $$ begin
  perform pg_temp.expect_error($q$select public.ingest_tank_reading('t', 'DEPO_01', 50, 'ACIK')$q$, array['42501']);
end $$;
reset role;
\echo 'OK  tokens are hashed, issued and used only server-side'

-- ===========================================================================
-- Ingest
-- ===========================================================================
select pg_temp.as_owner() \gset
do $$
declare r jsonb;
begin
  r := public.ingest_tank_reading('wrong', 'DEPO_01', 75, 'KAPALI');
  perform pg_temp.assert(r ->> 'status' = 'unauthorized', 'wrong token');
  r := public.ingest_tank_reading(current_setting('test.old_token'), 'DEPO_01', 75, 'KAPALI');
  perform pg_temp.assert(r ->> 'status' = 'unauthorized', 'revoked token');
  r := public.ingest_tank_reading(null, 'DEPO_01', 75, 'KAPALI');
  perform pg_temp.assert(r ->> 'status' = 'unauthorized', 'missing token');

  r := public.ingest_tank_reading(current_setting('test.token'), 'DEPO_99', 75, 'KAPALI');
  perform pg_temp.assert(r ->> 'status' = 'unknown_device', 'unknown device');
  -- a v1 device is not reachable through its id
  r := public.ingest_tank_reading(current_setting('test.token'), 'node-1001', 75, 'KAPALI');
  perform pg_temp.assert(r ->> 'status' = 'unknown_device', 'v1 device not addressable by text');

  perform pg_temp.expect_error($q$select public.ingest_tank_reading('x', 'DEPO_01', 150, 'ACIK')$q$, array['22023']);
  perform pg_temp.expect_error($q$select public.ingest_tank_reading('x', 'DEPO_01', 50, 'ACIK ')$q$, array['22023']);
  perform pg_temp.expect_error($q$select public.ingest_tank_reading('x', 'DEPO_01', 50, 'ACIK', 'bad id!')$q$, array['22023']);

  r := public.ingest_tank_reading(current_setting('test.token'), 'DEPO_01', 75, 'KAPALI', 'a1b2-1');
  perform pg_temp.assert(r ->> 'status' = 'ok' and (r ->> 'id') is not null, 'accepted: ' || r::text);
  r := public.ingest_tank_reading(current_setting('test.token'), 'DEPO_01', 75, 'KAPALI', 'a1b2-1');
  perform pg_temp.assert(r ->> 'status' = 'duplicate', 'resend is a duplicate');
  perform pg_temp.assert((select count(*) from public.telemetry where device_id = 'depo-01') = 1, 'one row');

  perform pg_temp.assert((select level_mm = 750 and valve = 0 and last_seen is not null
                            from public.devices where id = 'depo-01'), 'device state: 75% of 1000 mm, closed');
  perform pg_temp.assert((select last_seen > now() - interval '1 minute' from public.gateways where id = 'gw-text-01'),
                         'gateway marked alive');
  perform pg_temp.assert((select last_used_at is not null from public.ingest_tokens where label = 'test'), 'token last used');

  -- without a request id every call is a new row
  r := public.ingest_tank_reading(current_setting('test.token'), 'DEPO_01', 96, 'ACIK');
  perform pg_temp.assert(r ->> 'status' = 'ok', 'no request id');
  perform pg_temp.assert((select count(*) from public.alerts
                           where device_id = 'depo-01' and resolved_at is null) >= 1, 'level above 950 mm opens an alert');
end $$;
\echo 'OK  ingest: token, device, validation, idempotency, state and alerts'

-- ===========================================================================
-- Reading it back, commands
-- ===========================================================================
set role authenticated;
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $$ begin
  perform pg_temp.assert((select count(*) from public.tank_readings where device_id = 'DEPO_01') = 2, 'tank_readings rows');
  perform pg_temp.assert(exists (select 1 from public.tank_readings
                                  where device_id = 'DEPO_01' and level_percent = 75 and valve_state = 'KAPALI'),
                         'tank_readings shape');
  perform pg_temp.assert((select protocol = 'text' and code = 'DEPO_01' and address is null
                            from public.device_overview where id = 'depo-01'), 'overview has protocol and code');
end $$;
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$ begin
  perform pg_temp.expect_error($q$select public.send_command('depo-01', 'VANA_AC')$q$, array['23514']);
  perform public.send_command('node-1001', 'SIMDI_OKU');
end $$;
\echo 'OK  tank_readings view, overview fields, text devices take no commands'

reset role;
select pg_temp.as_owner() \gset
do $$ begin
  perform pg_temp.expect_error($q$insert into public.devices (id, name) values ('x', 'x')$q$, array['23514']);
  perform pg_temp.expect_error($q$insert into public.devices (id, name, protocol) values ('y', 'y', 'text')$q$, array['23514']);
  perform pg_temp.expect_error($q$insert into public.devices (id, name, protocol, code) values ('z', 'z', 'text', 'depo 1')$q$, array['23514']);
  insert into public.devices (id, name, protocol, code) values ('depo-02', 'Depo-02', 'text', 'DEPO_02');
  perform pg_temp.assert((select capacity_mm from public.devices where id = 'depo-02') = 1000, 'default capacity');
end $$;
\echo 'OK  device identity rules'

\echo 'ALL TESTS PASSED (text_ingest_test)'
