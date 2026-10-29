-- Tests for the fields the mobile design needs (20261102000500_mobile_design_fields.sql).
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
-- capacity_mm is admin-only; enabled is device state
-- ===========================================================================
do $t$ begin perform pg_temp.as_admin(); end $t$;
update public.devices set capacity_mm = 2000 where id = 'node-1001';
do $$ begin
  perform pg_temp.assert((select capacity_mm from public.device_overview where id = 'node-1001') = 2000, 'capacity in overview');
  perform pg_temp.assert((select enabled from public.device_overview where id = 'node-1001'), 'enabled by default');
  perform pg_temp.expect_error($q$update public.devices set enabled = false where id = 'node-1001'$q$, array['42501']);
  perform pg_temp.expect_error($q$update public.devices set capacity_mm = 0 where id = 'node-1001'$q$, array['23514']);
end $$;
do $t$ begin perform pg_temp.as_operator(); end $t$;
-- RLS gives operators no update on devices: the row is simply not touched
update public.devices set capacity_mm = 2500 where id = 'node-1001';
do $$ begin
  perform pg_temp.assert((select capacity_mm from public.devices where id = 'node-1001') = 2000, 'operator cannot change capacity');
end $$;
\echo 'OK  capacity_mm is admin-only, enabled cannot be set by users'

-- ===========================================================================
-- CIHAZ_ETKIN done -> devices.enabled; step times are stamped by the database
-- ===========================================================================
do $t$ begin perform pg_temp.as_operator(); end $t$;
do $$
declare c public.commands;
begin
  c := public.send_command('node-1002', 'CIHAZ_ETKIN', '{"enabled": false}', '33333333-3333-3333-3333-333333333333');
  perform pg_temp.assert(c.sent_at is null and c.delivered_at is null and c.finished_at is null, 'new command has no step times');
end $$;
do $t$ begin perform pg_temp.as_gateway(); end $t$;
do $$
declare r record; c public.commands;
begin
  select * into r from public.lease_next_command('gw-1');
  perform pg_temp.assert((select sent_at from public.commands where id = r.id) is null, 'lease is not "sent"');
  perform public.report_command(r.id, 'sent');
  perform public.report_command(r.id, 'delivered');
  perform pg_temp.assert((select enabled from public.devices where id = 'node-1002'), 'still enabled before done');
  perform public.report_command(r.id, 'done', 0::smallint);
  select * into c from public.commands where id = r.id;
  perform pg_temp.assert(c.sent_at is not null and c.delivered_at is not null and c.finished_at is not null, 'all steps stamped');
  perform pg_temp.assert(not (select enabled from public.devices where id = 'node-1002'), 'disabled after done');

  -- A client cannot write the times itself
  update public.commands set sent_at = '2000-01-01' where id = r.id;
  perform pg_temp.assert((select sent_at from public.commands where id = r.id) <> '2000-01-01', 'sent_at not writable');
end $$;
\echo 'OK  CIHAZ_ETKIN updates devices.enabled; command step times are server-stamped'

-- Expired commands get finished_at
reset role;
select pg_temp.as_owner() \gset
insert into public.commands (device_id, op, expires_at) values ('node-1003', 'SIMDI_OKU', now() - interval '1 second');
select public.expire_commands() \gset
do $$ begin
  perform pg_temp.assert((select finished_at is not null and sent_at is null from public.commands
                           where device_id = 'node-1003' and status = 'expired'), 'expired stamped as finished, never sent');
end $$;
\echo 'OK  expired commands are stamped as finished'

-- ===========================================================================
-- System account
-- ===========================================================================
set role authenticated;
do $$ begin
  perform pg_temp.assert((select is_system from public.profiles where id = '00000000-0000-0000-0000-00000000000b'), 'gateway is a system account');
  perform pg_temp.assert(not (select is_system from public.profiles where id = '00000000-0000-0000-0000-000000000001'), 'admin is a person');
end $$;
do $t$ begin perform pg_temp.as_admin(); end $t$;
do $$ begin
  perform pg_temp.expect_error($q$update public.profiles set role = 'operator' where id = '00000000-0000-0000-0000-00000000000b'$q$, array['42501']);
  perform pg_temp.expect_error($q$update public.profiles set is_system = true where id = '00000000-0000-0000-0000-000000000003'$q$, array['42501']);
  update public.profiles set role = 'operator' where id = '00000000-0000-0000-0000-000000000003';
  perform pg_temp.assert((select role::text from public.profiles where id = '00000000-0000-0000-0000-000000000003') = 'operator', 'admin still changes people');
end $$;
-- A user created later with the gateway role is flagged too (GoTrue writes auth.users
-- without a user JWT)
reset role;
select pg_temp.as_owner() \gset
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000c', 'gw2@test', '{"role": "gateway"}');
do $$ begin
  perform pg_temp.assert((select is_system from public.profiles where id = '00000000-0000-0000-0000-00000000000c'), 'new gateway account flagged');
end $$;
\echo 'OK  gateway accounts are system accounts with a fixed role'

\echo 'ALL MOBILE FIELD TESTS PASSED'
