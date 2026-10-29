-- LoRa Water Management System - command lifecycle
--
-- State machine (docs/02-sistem-mimarisi.md §4.6):
--
--   pending ──claim──> sent ──ACK──> delivered ──CMD_RESULT──> done | failed
--      │                 └──────────CMD_RESULT / no ACK──────> done | failed
--      ├──unknown op──> failed
--      └──expires_at passed──> expired           (pg_cron, expire_commands)
--   sent / delivered stuck too long ──> failed (Timeout)  (pg_cron, expire_commands)
--
-- Adds:
--   * commands.expires_at and validation of op/args on insert (any insert path)
--   * at most one unfinished command per device
--   * a guard that allows only the transitions above and freezes the request columns
--   * public.send_command()      - app entry point with friendly errors
--   * public.claim_next_command() - gateway entry point: atomic "take one pending command"
--   * public.expire_commands()   - scheduled every minute with pg_cron

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
-- How long a command may wait for the gateway before it expires
create or replace function public.command_ttl() returns interval
  language sql immutable as $$ select interval '2 minutes' $$;

-- How long a command may stay 'sent'/'delivered' before it counts as lost
create or replace function public.command_stuck_after() returns interval
  language sql immutable as $$ select interval '5 minutes' $$;

-- ---------------------------------------------------------------------------
-- Columns and constraints
-- ---------------------------------------------------------------------------
alter table public.commands
  add column expires_at timestamptz not null default now() + interval '2 minutes';

-- Existing unfinished rows from before this migration: let them expire normally
update public.commands set expires_at = created_at + public.command_ttl()
 where status = 'pending';

-- At most one unfinished command per device. The real valve state is only known once
-- the device replies, so commands to one device are strictly sequential.
create unique index commands_one_active_idx on public.commands (device_id)
  where status in ('pending', 'sent', 'delivered');

-- The gateway takes the oldest live pending command
drop index if exists public.commands_pending_idx;
create index commands_pending_idx on public.commands (id)
  where status = 'pending';
create index commands_inflight_idx on public.commands (updated_at)
  where status in ('sent', 'delivered');

-- ---------------------------------------------------------------------------
-- Validation on insert (applies to send_command() and to direct REST inserts)
-- ---------------------------------------------------------------------------
create or replace function public.validate_command() returns trigger
  language plpgsql set search_path = public
as $$
declare
  secs numeric;
begin
  -- Arguments per op (they must fit the LoRa COMMAND payload, docs/03-protokol.md)
  case new.op
    when 'VANA_AC', 'VANA_KAPAT', 'SIMDI_OKU' then
      if new.args is not null and new.args <> '{}'::jsonb then
        raise exception '% takes no arguments', new.op using errcode = 'check_violation';
      end if;
      new.args := null;

    when 'CIHAZ_ETKIN' then
      if jsonb_typeof(new.args -> 'enabled') is distinct from 'boolean' then
        raise exception 'CIHAZ_ETKIN needs {"enabled": true|false}' using errcode = 'check_violation';
      end if;
      new.args := jsonb_build_object('enabled', new.args -> 'enabled');

    when 'PERIYOT_AYARLA' then
      if jsonb_typeof(new.args -> 'seconds') is distinct from 'number' then
        raise exception 'PERIYOT_AYARLA needs {"seconds": 10..65535}' using errcode = 'check_violation';
      end if;
      secs := (new.args ->> 'seconds')::numeric;
      if secs <> trunc(secs) or secs not between 10 and 65535 then
        raise exception 'PERIYOT_AYARLA seconds must be an integer in 10..65535'
          using errcode = 'check_violation';
      end if;
      new.args := jsonb_build_object('seconds', secs::integer);

    else
      null;  -- unknown ops are already rejected by the op check constraint
  end case;

  -- Users cannot choose their own deadline; the database owner (tests, SQL Editor) can
  if auth.uid() is not null then
    new.expires_at := now() + public.command_ttl();
  end if;
  return new;
end
$$;

create trigger commands_validate
  before insert on public.commands
  for each row execute function public.validate_command();

-- ---------------------------------------------------------------------------
-- Transition guard (applies to the gateway's PATCH requests and to pg_cron)
-- ---------------------------------------------------------------------------
create or replace function public.guard_command_update() returns trigger
  language plpgsql set search_path = public
as $$
begin
  -- The request itself never changes after insert
  if (new.device_id, new.op, new.args, new.created_by, new.created_at, new.expires_at)
     is distinct from
     (old.device_id, old.op, old.args, old.created_by, old.created_at, old.expires_at)
     and auth.uid() is not null then
    raise exception 'Command request columns are read-only' using errcode = 'insufficient_privilege';
  end if;

  -- Repeating the current status (e.g. a retried PATCH) is a harmless no-op
  if new.status = old.status then
    return new;
  end if;

  if not (
       (old.status = 'pending'   and new.status in ('sent', 'failed', 'expired'))
    or (old.status = 'sent'      and new.status in ('delivered', 'done', 'failed'))
    or (old.status = 'delivered' and new.status in ('done', 'failed'))
  ) then
    raise exception 'Invalid command transition % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;

create trigger commands_guard
  before update on public.commands
  for each row execute function public.guard_command_update();

-- ---------------------------------------------------------------------------
-- PERIYOT_AYARLA: apply the new period only when the value is valid.
-- Defensive on purpose: a bad value must never roll back the gateway's 'done'
-- update and leave the command stuck (insert validation already rejects it).
-- ---------------------------------------------------------------------------
create or replace function public.apply_period_command() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  secs integer;
begin
  if new.op = 'PERIYOT_AYARLA' and new.status = 'done' and old.status is distinct from 'done' then
    begin
      secs := (new.args ->> 'seconds')::integer;
    exception when others then
      secs := null;
    end;
    if secs between 10 and 65535 then
      update public.devices set period_s = secs where id = new.device_id;
    else
      raise warning 'command %: ignoring invalid period %', new.id, new.args;
    end if;
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- App entry point
-- ---------------------------------------------------------------------------
-- Runs as the caller (security invoker), so the "operator inserts" RLS policy applies.
-- Returns the new row; errors carry Turkish messages the app can show as they are.
create or replace function public.send_command(p_device_id text, p_op text, p_args jsonb default null)
  returns public.commands
  language plpgsql security invoker set search_path = public
as $$
declare
  r public.commands;
begin
  insert into public.commands (device_id, op, args)
  values (p_device_id, p_op, p_args)
  returning * into r;
  return r;
exception
  when unique_violation then
    raise exception 'Bu cihaz için tamamlanmamış bir komut var' using errcode = 'unique_violation';
  when foreign_key_violation then
    raise exception 'Cihaz bulunamadı: %', p_device_id using errcode = 'foreign_key_violation';
  when insufficient_privilege then
    raise exception 'Komut göndermek için operatör ya da yönetici olmalısınız'
      using errcode = 'insufficient_privilege';
end
$$;
revoke execute on function public.send_command(text, text, jsonb) from public, anon;
grant execute on function public.send_command(text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Gateway entry point
-- ---------------------------------------------------------------------------
-- Takes the oldest live pending command and marks it 'sent' in one statement, so it
-- can never be picked twice (two gateways, a retried request). The gateway sends the
-- LoRa frame after this returns. Expired commands are never returned.
create or replace function public.claim_next_command()
  returns table (id bigint, device_id text, address integer, op text, args jsonb)
  language plpgsql security invoker set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_gateway() then
    raise exception 'Only the gateway can claim commands' using errcode = 'insufficient_privilege';
  end if;

  return query
  with next as (
    select c.id
      from public.commands c
     where c.status = 'pending' and c.expires_at > now()
     order by c.id
     limit 1
       for update skip locked
  ), claimed as (
    update public.commands c
       set status = 'sent'
      from next
     where c.id = next.id
    returning c.id, c.device_id, c.op, c.args
  )
  select cl.id, cl.device_id, d.address, cl.op, cl.args
    from claimed cl
    join public.devices d on d.id = cl.device_id;
end
$$;
revoke execute on function public.claim_next_command() from public, anon;
grant execute on function public.claim_next_command() to authenticated;

-- ---------------------------------------------------------------------------
-- Housekeeping (pg_cron, every minute)
-- ---------------------------------------------------------------------------
-- Returns the number of commands it closed.
create or replace function public.expire_commands() returns integer
  language plpgsql security definer set search_path = public
as $$
declare
  n_expired integer;
  n_lost integer;
begin
  update public.commands set status = 'expired'
   where status = 'pending' and expires_at <= now();
  get diagnostics n_expired = row_count;

  -- In flight for too long: the gateway restarted or lost the reply.
  -- result 3 = Timeout (firmware/lib/LoraProtocol Result::Timeout)
  update public.commands set status = 'failed', result = 3
   where status in ('sent', 'delivered') and updated_at <= now() - public.command_stuck_after();
  get diagnostics n_lost = row_count;

  return n_expired + n_lost;
end
$$;
revoke execute on function public.expire_commands() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('expire-commands', '* * * * *', 'select public.expire_commands()');
  else
    raise notice 'pg_cron not available: schedule public.expire_commands() another way';
  end if;
exception when others then
  raise notice 'pg_cron setup skipped: %', sqlerrm;
end
$$;
