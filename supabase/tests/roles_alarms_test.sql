-- Tests for roles, thresholds, alerts and push tokens (20261018000000_roles_alarms.sql).
-- Run with: backend/supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- Profiles are created by the auth.users trigger
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000001', 'admin@test',    '{"full_name":"Ayşe Yönetici"}'),
  ('00000000-0000-0000-0000-000000000002', 'operator@test', '{}'),
  ('00000000-0000-0000-0000-000000000003', 'viewer@test',   '{}'),
  ('00000000-0000-0000-0000-00000000000b', 'gateway@test',  '{}');
do $$
begin
  if (select count(*) from public.profiles) <> 4 then raise exception 'profiles not created by trigger'; end if;
  if (select role from public.profiles where id = '00000000-0000-0000-0000-000000000003') <> 'viewer' then
    raise exception 'default role is not viewer';
  end if;
  if (select full_name from public.profiles where id = '00000000-0000-0000-0000-000000000001') <> 'Ayşe Yönetici' then
    raise exception 'full_name not copied from metadata';
  end if;
  if (select email from public.profiles where id = '00000000-0000-0000-0000-000000000002') <> 'operator@test' then
    raise exception 'email not copied';
  end if;
end $$;
-- Bootstrap roles as the database owner (SQL Editor), as described in the migration header
update public.profiles set role = 'admin'    where id = '00000000-0000-0000-0000-000000000001';
update public.profiles set role = 'operator' where id = '00000000-0000-0000-0000-000000000002';
\echo 'OK  auth.users trigger creates viewer profiles; owner bootstraps roles'

\i seed.sql

create function pg_temp.as_(sub text, app_role text default null) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', sub,
      'app_metadata', case when app_role is null then '{}'::json else json_build_object('role', app_role) end)::text,
    false);
$$;
create function pg_temp.as_admin() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-000000000001') $$;
create function pg_temp.as_operator() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-000000000002') $$;
create function pg_temp.as_viewer() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-000000000003') $$;
create function pg_temp.as_gateway() returns void language sql as
  $$ select pg_temp.as_('00000000-0000-0000-0000-00000000000b', 'gateway') $$;
create function pg_temp.as_owner() returns void language sql as
  $$ select set_config('request.jwt.claims', '', false) $$;
create function pg_temp.expect_denied(sql text) returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'UNEXPECTED: allowed -> %', sql;
exception when insufficient_privilege or check_violation then
  null;  -- expected
end $$;
create function pg_temp.expect_rows(sql text, expected int) returns void language plpgsql as $$
declare n int;
begin
  execute sql;
  get diagnostics n = row_count;
  if n <> expected then raise exception 'expected % rows, got % -> %', expected, n, sql; end if;
end $$;
create function pg_temp.open_alerts(dev text, k text) returns bigint language sql as $$
  select count(*) from public.alerts where device_id = dev and kind = k and resolved_at is null
$$;

set role authenticated;

-- ---------------------------------------------------------------------------
-- Commands by role
-- ---------------------------------------------------------------------------
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$ begin perform pg_temp.expect_denied($$insert into public.commands (device_id, op) values ('node-1001', 'VANA_AC')$$); end $t$;
\echo 'OK  viewer cannot insert commands'

do $t$ begin perform pg_temp.as_operator(); end $t$;
insert into public.commands (device_id, op) values ('node-1001', 'VANA_AC');
\echo 'OK  operator inserts commands'

do $t$ begin perform pg_temp.as_admin(); end $t$;
insert into public.commands (device_id, op) values ('node-1002', 'SIMDI_OKU');  -- node-1001 already has an unfinished command
\echo 'OK  admin inserts commands'

do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $t$ begin perform pg_temp.expect_denied($$insert into public.commands (device_id, op) values ('node-1001', 'VANA_AC')$$); end $t$;
\echo 'OK  gateway cannot insert commands'

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $$
begin
  if (select count(*) from public.profiles) <> 4 then raise exception 'viewer cannot read all profiles'; end if;
end $$;
\echo 'OK  authenticated users read profiles'

do $t$ begin perform pg_temp.as_admin(); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.profiles set role = 'operator' where id = '00000000-0000-0000-0000-000000000003'$$, 1); end $t$;
do $$
begin
  if (select role from public.profiles where id = '00000000-0000-0000-0000-000000000003') <> 'operator' then
    raise exception 'admin could not change role';
  end if;
end $$;
update public.profiles set role = 'viewer' where id = '00000000-0000-0000-0000-000000000003';
\echo 'OK  admin changes roles'

do $t$ begin perform pg_temp.as_operator(); end $t$;
-- Other users' rows are not updatable (RLS: 0 rows)
do $t$ begin perform pg_temp.expect_rows($$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-000000000003'$$, 0); end $t$;
-- Own role: blocked by the guard trigger
do $t$ begin perform pg_temp.expect_denied($$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-000000000002'$$); end $t$;
\echo 'OK  operator cannot change roles'

do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$ begin perform pg_temp.expect_denied($$update public.profiles set role = 'admin' where id = auth.uid()$$); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.profiles set full_name = 'Veli İzleyici' where id = auth.uid()$$, 1); end $t$;
do $$
begin
  if (select role from public.profiles where id = auth.uid()) <> 'viewer' then raise exception 'role changed'; end if;
end $$;
\echo 'OK  user cannot change own role but can change own full_name'

do $t$ begin perform pg_temp.as_admin(); end $t$;
do $t$ begin perform pg_temp.expect_denied($$update public.profiles set role = 'viewer' where id = auth.uid()$$); end $t$;
\echo 'OK  last admin cannot be demoted'

-- ---------------------------------------------------------------------------
-- Thresholds
-- ---------------------------------------------------------------------------
do $t$ begin perform pg_temp.as_admin(); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.devices set level_high_mm = 1500, level_low_mm = 200, offline_after_s = 600 where id = 'node-1001'$$, 1); end $t$;
update public.devices set name = 'Depo-1' where id = 'node-1001';
do $$
begin
  if (select level_high_mm from public.devices where id = 'node-1001') <> 1500 then
    raise exception 'admin could not change thresholds';
  end if;
end $$;
\echo 'OK  admin changes thresholds and name'

do $t$ begin perform pg_temp.expect_denied($$update public.devices set level_mm = 1 where id = 'node-1001'$$); end $t$;
\echo 'OK  admin cannot change device state columns'

do $t$ begin perform pg_temp.as_operator(); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.devices set level_high_mm = 9999 where id = 'node-1001'$$, 0); end $t$;
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.devices set level_high_mm = 9999 where id = 'node-1001'$$, 0); end $t$;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $t$ begin perform pg_temp.expect_denied($$update public.devices set level_high_mm = 9999 where id = 'node-1001'$$); end $t$;
\echo 'OK  operator, viewer and gateway cannot change thresholds'

-- ---------------------------------------------------------------------------
-- Alerts from telemetry (node-1001: level 200..1500 mm, pressure 50..400 cbar)
-- ---------------------------------------------------------------------------
do $t$ begin perform pg_temp.as_gateway(); end $t$;
insert into public.telemetry (device_id, level_mm, pressure_cbar, alarms) values ('node-1001', 1000, 200, 0);
do $$
begin
  if (select count(*) from public.alerts) <> 0 then raise exception 'alert opened for normal values'; end if;
end $$;

insert into public.telemetry (device_id, level_mm) values ('node-1001', 1600);
insert into public.telemetry (device_id, level_mm) values ('node-1001', 1700);
do $$
begin
  if pg_temp.open_alerts('node-1001', 'level_high') <> 1 then raise exception 'level_high not opened exactly once'; end if;
  if (select value from public.alerts where kind = 'level_high') <> 1600 then raise exception 'wrong alert value'; end if;
  if (select message from public.alerts where kind = 'level_high') not like 'Depo seviyesi yüksek%' then
    raise exception 'unexpected message';
  end if;
end $$;
\echo 'OK  telemetry above threshold opens one alert'

insert into public.telemetry (device_id, level_mm) values ('node-1001', 1200);
do $$
begin
  if pg_temp.open_alerts('node-1001', 'level_high') <> 0 then raise exception 'level_high not resolved'; end if;
  if (select resolved_at from public.alerts where kind = 'level_high') is null then raise exception 'resolved_at missing'; end if;
end $$;
\echo 'OK  normal value resolves the alert'

insert into public.telemetry (device_id, level_mm, pressure_cbar, alarms) values ('node-1001', 100, 20, 5);
do $$
begin
  if pg_temp.open_alerts('node-1001', 'level_low') <> 1 then raise exception 'level_low not opened'; end if;
  if pg_temp.open_alerts('node-1001', 'pressure_low') <> 1 then raise exception 'pressure_low not opened'; end if;
  if pg_temp.open_alerts('node-1001', 'device_alarm') <> 1 then raise exception 'device_alarm not opened'; end if;
  if (select message from public.alerts where kind = 'device_alarm') <> 'Cihaz alarmı: Taşma, Sensör hatası' then
    raise exception 'device_alarm message: %', (select message from public.alerts where kind = 'device_alarm');
  end if;
  if (select message from public.alerts where kind = 'pressure_low') <> 'Basınç düşük: 0,20 bar (alt eşik 0,50 bar)' then
    raise exception 'pressure_low message: %', (select message from public.alerts where kind = 'pressure_low');
  end if;
end $$;
insert into public.telemetry (device_id, level_mm, pressure_cbar, alarms) values ('node-1001', 1000, 200, 0);
do $$
begin
  if (select count(*) from public.alerts where resolved_at is null) <> 0 then raise exception 'alerts not resolved'; end if;
end $$;
\echo 'OK  level_low, pressure_low, device_alarm open and resolve'

-- Users read alerts but cannot write them
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $$
begin
  if (select count(*) from public.alerts) = 0 then raise exception 'viewer cannot read alerts'; end if;
end $$;
do $t$ begin perform pg_temp.expect_denied($$insert into public.alerts (device_id, kind, message) values ('node-1001', 'offline', 'x')$$); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.alerts set resolved_at = null$$, 0); end $t$;
\echo 'OK  alerts are read-only for users'

-- ---------------------------------------------------------------------------
-- Offline alerts
-- ---------------------------------------------------------------------------
reset role;
do $t$ begin perform pg_temp.as_owner(); end $t$;
update public.devices set last_seen = now() - interval '20 minutes' where id = 'node-1001';
update public.devices set last_seen = now() - interval '1 minute'   where id = 'node-1002';
do $$
begin
  if public.check_offline_devices() <> 1 then raise exception 'expected 1 offline alert'; end if;
  if public.check_offline_devices() <> 0 then raise exception 'offline alert opened twice'; end if;
  if pg_temp.open_alerts('node-1001', 'offline') <> 1 then raise exception 'offline not opened'; end if;
  if pg_temp.open_alerts('node-1002', 'offline') <> 0 then raise exception 'node-1002 wrongly offline'; end if;
end $$;
\echo 'OK  check_offline_devices opens offline alert'

set role authenticated;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
update public.devices set last_seen = 'now' where id = 'node-1001';   -- heartbeat
do $$
begin
  if pg_temp.open_alerts('node-1001', 'offline') <> 0 then raise exception 'offline not resolved by heartbeat'; end if;
end $$;
\echo 'OK  heartbeat resolves offline alert'

reset role;
do $t$ begin perform pg_temp.as_owner(); end $t$;
update public.devices set last_seen = now() - interval '20 minutes' where id = 'node-1001';
do $t$ begin perform public.check_offline_devices(); end $t$;
set role authenticated;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
insert into public.telemetry (device_id, level_mm) values ('node-1001', 1000);
do $$
begin
  if pg_temp.open_alerts('node-1001', 'offline') <> 0 then raise exception 'offline not resolved by telemetry'; end if;
end $$;
\echo 'OK  telemetry resolves offline alert'

do $t$ begin perform pg_temp.as_admin(); end $t$;
do $t$ begin perform pg_temp.expect_denied($$select public.check_offline_devices()$$); end $t$;
\echo 'OK  users cannot call check_offline_devices'

-- ---------------------------------------------------------------------------
-- Push tokens
-- ---------------------------------------------------------------------------
do $t$ begin perform pg_temp.as_operator(); end $t$;
insert into public.push_tokens (token, platform) values ('ExponentPushToken[op-1]', 'android');
do $t$ begin perform pg_temp.as_viewer(); end $t$;
do $t$ begin perform public.register_push_token('ExponentPushToken[viewer-1]', 'ios'); end $t$;
do $t$ begin perform public.register_push_token('ExponentPushToken[viewer-1]', 'ios'); end $t$;   -- idempotent
do $$
begin
  if (select count(*) from public.push_tokens) <> 1 then raise exception 'viewer sees other tokens'; end if;
end $$;
do $t$ begin perform pg_temp.expect_denied($$insert into public.push_tokens (token, user_id) values ('x', '00000000-0000-0000-0000-000000000002')$$); end $t$;
do $t$ begin perform pg_temp.expect_rows($$delete from public.push_tokens where token = 'ExponentPushToken[op-1]'$$, 0); end $t$;
do $t$ begin perform pg_temp.expect_rows($$update public.push_tokens set platform = 'x' where token = 'ExponentPushToken[op-1]'$$, 0); end $t$;
\echo 'OK  users see and change only their own push tokens'

-- Same phone signs in as another user: the token moves to that user
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $t$ begin perform public.register_push_token('ExponentPushToken[viewer-1]', 'ios'); end $t$;
do $$
begin
  if (select count(*) from public.push_tokens) <> 2 then raise exception 'token not moved to operator'; end if;
end $$;
do $t$ begin perform pg_temp.expect_rows($$delete from public.push_tokens where token = 'ExponentPushToken[viewer-1]'$$, 1); end $t$;
\echo 'OK  register_push_token moves a token to the current user'

reset role;
\echo 'ALL TESTS PASSED (roles_alarms_test)'
