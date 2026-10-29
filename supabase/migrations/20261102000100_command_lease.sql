-- LoRa Water Management System - leased command claims, idempotent reports and sends
--
-- Problems with 20261101000100_command_lifecycle.sql this migration fixes:
--   * claim_next_command() marks the command 'sent' before the gateway has it. If the HTTP
--     response is lost, the command is never transmitted and only fails 5 minutes later.
--   * A lost ACK makes the gateway write 'failed' (Timeout) although the node may have run
--     the command; its later CMD_RESULT ('done') was rejected as an invalid transition.
--   * A retried send_command() (flaky mobile network) could not tell "already queued" from
--     "another command is running".
--
-- New state machine (additions marked with *):
--
--   pending ──lease*──> pending (leased, lease_until) ──report 'sent'*──> sent ...
--      lease expires without a report -> leased again (same or another gateway)
--   sent / delivered ──> done | failed                       (unchanged)
--   failed (result 3 = Timeout) ──late CMD_RESULT*──> done | failed (within 10 minutes)
--   expired (was leased) ──late report*──> sent | delivered | done | failed
--
-- Adds:
--   * commands.claimed_by, lease_until, attempts, client_request_id
--   * public.lease_next_command(gateway_id) - gateway entry point (used by gateway_sync)
--   * public.report_command(id, status, result) - idempotent status report
--   * public.send_command(..., p_client_request_id) - idempotent app entry point
-- claim_next_command() stays for gateways running the old firmware.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
-- How long a leased command is reserved for one gateway before it can be leased again
create or replace function public.command_lease() returns interval
  language sql immutable as $$ select interval '15 seconds' $$;

-- How long after a Timeout a late CMD_RESULT may still correct the outcome
create or replace function public.command_correction_window() returns interval
  language sql immutable as $$ select interval '10 minutes' $$;

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.commands
  add column claimed_by        text,
  add column lease_until       timestamptz,
  add column attempts          smallint not null default 0,
  add column client_request_id uuid;

-- Retried sends from the app carry the same id. Unique per user, so one user cannot
-- probe another user's ids.
create unique index commands_client_request_idx on public.commands (created_by, client_request_id)
  where client_request_id is not null;

-- History per device (app detail screen)
create index commands_device_created_idx on public.commands (device_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Transition guard
-- ---------------------------------------------------------------------------
create or replace function public.guard_command_update() returns trigger
  language plpgsql set search_path = public
as $$
begin
  -- The request itself never changes after insert
  if (new.device_id, new.op, new.args, new.created_by, new.created_at, new.expires_at, new.client_request_id)
     is distinct from
     (old.device_id, old.op, old.args, old.created_by, old.created_at, old.expires_at, old.client_request_id)
     and auth.uid() is not null then
    raise exception 'Command request columns are read-only' using errcode = 'insufficient_privilege';
  end if;

  -- Repeating the current status (a retried PATCH or report, a lease) is a harmless no-op
  if new.status = old.status then
    return new;
  end if;

  if not (
       (old.status = 'pending'   and new.status in ('sent', 'failed', 'expired'))
    or (old.status = 'sent'      and new.status in ('delivered', 'done', 'failed'))
    or (old.status = 'delivered' and new.status in ('done', 'failed'))
    -- The node answered after the gateway gave up waiting for its ACK
    or (old.status = 'failed' and old.result = 3 and new.status in ('done', 'failed')
        and old.updated_at > now() - public.command_correction_window())
    -- The gateway transmitted a leased command just before the expiry job ran
    or (old.status = 'expired' and old.claimed_by is not null
        and new.status in ('sent', 'delivered', 'done', 'failed')
        and old.updated_at > now() - public.command_correction_window())
  ) then
    raise exception 'Invalid command transition % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- Expiry job: a command whose lease is still running is in the gateway's hands
-- ---------------------------------------------------------------------------
create or replace function public.expire_commands() returns integer
  language plpgsql security definer set search_path = public
as $$
declare
  n_expired integer;
  n_lost integer;
begin
  update public.commands set status = 'expired'
   where status = 'pending' and expires_at <= now()
     and (lease_until is null or lease_until <= now());
  get diagnostics n_expired = row_count;

  -- In flight for too long: the gateway restarted or lost the reply.
  -- result 3 = Timeout (firmware/lib/LoraProtocol Result::Timeout)
  update public.commands set status = 'failed', result = 3
   where status in ('sent', 'delivered') and updated_at <= now() - public.command_stuck_after();
  get diagnostics n_lost = row_count;

  return n_expired + n_lost;
end
$$;

-- ---------------------------------------------------------------------------
-- App entry point (idempotent with p_client_request_id)
-- ---------------------------------------------------------------------------
drop function public.send_command(text, text, jsonb);

-- Runs as the caller (security invoker), so the "operator inserts" RLS policy applies.
-- With p_client_request_id, repeating the call returns the row of the first call instead
-- of failing. Errors carry Turkish messages the app can show as they are.
create or replace function public.send_command(
  p_device_id text,
  p_op text,
  p_args jsonb default null,
  p_client_request_id uuid default null
)
  returns public.commands
  language plpgsql security invoker set search_path = public
as $$
declare
  r public.commands;
  constraint_name text;
begin
  if p_client_request_id is not null then
    select * into r from public.commands
     where created_by = auth.uid() and client_request_id = p_client_request_id;
    if found then
      return r;
    end if;
  end if;

  insert into public.commands (device_id, op, args, client_request_id)
  values (p_device_id, p_op, p_args, p_client_request_id)
  returning * into r;
  return r;
exception
  when unique_violation then
    get stacked diagnostics constraint_name = constraint_name;
    if constraint_name = 'commands_client_request_idx' then
      -- A concurrent retry of the same request won the race
      select * into r from public.commands
       where created_by = auth.uid() and client_request_id = p_client_request_id;
      return r;
    end if;
    raise exception 'Bu cihaz için tamamlanmamış bir komut var' using errcode = 'unique_violation';
  when foreign_key_violation then
    raise exception 'Cihaz bulunamadı: %', p_device_id using errcode = 'foreign_key_violation';
  when insufficient_privilege then
    raise exception 'Komut göndermek için operatör ya da yönetici olmalısınız'
      using errcode = 'insufficient_privilege';
end
$$;
revoke execute on function public.send_command(text, text, jsonb, uuid) from public, anon;
grant execute on function public.send_command(text, text, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Gateway entry points
-- ---------------------------------------------------------------------------
-- Reserves the oldest live pending command for p_gateway_id for command_lease(). The
-- status stays 'pending' until the gateway reports 'sent', so a lost response only costs
-- the lease time: the command is leased again afterwards. Returns no row when the queue
-- is empty.
create or replace function public.lease_next_command(p_gateway_id text)
  returns table (id bigint, device_id text, address integer, op text, args jsonb)
  language plpgsql security invoker set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_gateway() then
    raise exception 'Only the gateway can claim commands' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_gateway_id, '') = '' then
    raise exception 'p_gateway_id is required' using errcode = 'invalid_parameter_value';
  end if;

  return query
  with next as (
    select c.id
      from public.commands c
     where c.status = 'pending' and c.expires_at > now()
       and (c.lease_until is null or c.lease_until <= now())
     order by c.id
     limit 1
       for update skip locked
  ), leased as (
    update public.commands c
       set claimed_by = p_gateway_id,
           lease_until = now() + public.command_lease(),
           attempts = c.attempts + 1
      from next
     where c.id = next.id
    returning c.id, c.device_id, c.op, c.args
  )
  select l.id, l.device_id, d.address, l.op, l.args
    from leased l
    join public.devices d on d.id = l.device_id;
end
$$;
revoke execute on function public.lease_next_command(text) from public, anon;
grant execute on function public.lease_next_command(text) to authenticated;

-- Records what happened to a command. Safe to repeat: the same report twice is a no-op,
-- and a report the state machine does not allow is ignored instead of failing, so a
-- gateway can keep retrying its queue until it gets an answer.
-- Returns 'ok', 'noop' (already in that state), 'rejected' or 'unknown' (no such command).
create or replace function public.report_command(p_id bigint, p_status public.command_status, p_result smallint default null)
  returns text
  language plpgsql security invoker set search_path = public
as $$
declare
  cur public.commands;
begin
  if not public.is_gateway() then
    raise exception 'Only the gateway can report commands' using errcode = 'insufficient_privilege';
  end if;
  if p_status not in ('sent', 'delivered', 'done', 'failed') then
    raise exception 'Gateways report sent, delivered, done or failed' using errcode = 'invalid_parameter_value';
  end if;

  select * into cur from public.commands where id = p_id for update;
  if not found then
    return 'unknown';
  end if;

  -- An ACK report can arrive after the result; never move backwards
  if cur.status = p_status and cur.result is not distinct from coalesce(p_result, cur.result)
     or (cur.status = 'done' and p_status in ('sent', 'delivered'))
     or (cur.status = 'delivered' and p_status = 'sent')
     or (cur.status = 'failed' and cur.result is distinct from 3 and p_status in ('sent', 'delivered')) then
    return 'noop';
  end if;

  begin
    update public.commands
       set status = p_status,
           result = coalesce(p_result, result),
           lease_until = null
     where id = p_id;
  exception when check_violation then
    return 'rejected';
  end;
  return 'ok';
end
$$;
revoke execute on function public.report_command(bigint, public.command_status, smallint) from public, anon;
grant execute on function public.report_command(bigint, public.command_status, smallint) to authenticated;
