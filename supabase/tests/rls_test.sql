-- Schema and RLS policy tests. Run with: backend/supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on

grant usage on schema public to authenticated;
grant select, insert, update on all tables in schema public to authenticated;

insert into auth.users values
  ('00000000-0000-0000-0000-00000000000a'),   -- regular user
  ('00000000-0000-0000-0000-00000000000b');   -- gateway
-- The regular user must be an operator to send commands (20261018000000_roles_alarms.sql)
update public.profiles set role = 'operator' where id = '00000000-0000-0000-0000-00000000000a';
\i seed.sql

create function pg_temp.as_user() returns void language sql as $$
  select set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000a","app_metadata":{}}', false);
$$;
create function pg_temp.as_gateway() returns void language sql as $$
  select set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-00000000000b","app_metadata":{"role":"gateway"}}', false);
$$;
create function pg_temp.expect_denied(sql text) returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'UNEXPECTED: allowed -> %', sql;
exception when insufficient_privilege or check_violation then
  null;  -- expected
end $$;

set role authenticated;

-- 1) User (operator) can insert a command
do $t$ begin perform pg_temp.as_user(); end $t$;
insert into public.commands (device_id, op) values ('node-1001', 'VANA_AC');
\echo 'OK  operator inserts pending command'

-- 2) User cannot insert a command with status 'done'
do $t$ begin perform pg_temp.expect_denied($$insert into public.commands (device_id, op, status) values ('node-1001','VANA_AC','done')$$); end $t$;
\echo 'OK  user cannot insert done command'

-- 3) User cannot insert telemetry
do $t$ begin perform pg_temp.expect_denied($$insert into public.telemetry (device_id, level_mm) values ('node-1001', 5)$$); end $t$;
\echo 'OK  user cannot insert telemetry'

-- 4) User cannot change command status (RLS hides the rows: 0 rows updated)
do $$
declare n int;
begin
  update public.commands set status = 'done';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'user updated a command'; end if;
end $$;
\echo 'OK  user cannot change command status'

-- 5) Gateway inserts telemetry; trigger updates the devices row
do $t$ begin perform pg_temp.as_gateway(); end $t$;
insert into public.telemetry (device_id, level_mm, valve) values ('node-1001', 1250, 1);
do $$
begin
  if (select level_mm from public.devices where id = 'node-1001') <> 1250 then
    raise exception 'trigger did not update devices.level_mm';
  end if;
  if (select last_seen from public.devices where id = 'node-1001') is null then
    raise exception 'last_seen is null';
  end if;
end $$;
\echo 'OK  gateway inserts telemetry, devices updated'

-- 6) Gateway updates command status (pending -> sent -> done, as the firmware does)
update public.commands set status = 'sent' where op = 'VANA_AC';
update public.commands set status = 'done', result = 0 where op = 'VANA_AC';
do $$
begin
  if (select count(*) from public.commands where status = 'done') <> 1 then
    raise exception 'gateway could not update the command';
  end if;
end $$;
\echo 'OK  gateway updates command status'

-- 7) Completing PERIYOT_AYARLA updates devices.period_s
do $t$ begin perform pg_temp.as_user(); end $t$;
insert into public.commands (device_id, op, args) values ('node-1001', 'PERIYOT_AYARLA', '{"seconds": 30}');
do $t$ begin perform pg_temp.as_gateway(); end $t$;
update public.commands set status = 'sent' where op = 'PERIYOT_AYARLA';
update public.commands set status = 'done', result = 0 where op = 'PERIYOT_AYARLA';
do $$
begin
  if (select period_s from public.devices where id = 'node-1001') <> 30 then
    raise exception 'period_s not updated';
  end if;
end $$;
\echo 'OK  PERIYOT_AYARLA updates devices.period_s'

-- 8) Gateway writes a heartbeat using "now" (the gateway service sends this value)
insert into public.gateways (id, fw, last_seen) values ('gw-01', '0.1.0', 'now');
update public.devices set last_seen = 'now', fw = '0.1.0' where id = 'node-1002';
\echo 'OK  gateway writes heartbeat'

-- 9) Signed-out (anon) users see no data. In Supabase anon has table grants,
--    but no RLS policy allows it, so 0 rows are returned.
reset role;
grant usage on schema public to anon;
grant select on all tables in schema public to anon;
set role anon;
do $$
begin
  if (select count(*) from public.devices) <> 0 then raise exception 'anon saw devices'; end if;
  if (select count(*) from public.commands) <> 0 then raise exception 'anon saw commands'; end if;
end $$;
\echo 'OK  anon cannot read'

reset role;
\echo 'ALL TESTS PASSED (rls_test)'
