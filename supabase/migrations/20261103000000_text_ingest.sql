-- LoRa Water Management System - text protocol nodes over the ingest-tank Edge Function
-- (ADR-0011, docs/03-protokol.md "Metin protokolü (v0)")
--
-- The working field hardware sends "DEPO_01,75,KAPALI" (level in percent, valve ACIK or
-- KAPALI) over transparent LoRa. A simple gateway (firmware env gateway-text) posts each
-- line as JSON to the ingest-tank Edge Function with an X-Device-Token header. The data
-- lands in the same devices/telemetry tables as protocol v1, so cards, alerts, history
-- and widgets work unchanged.
--
--   * devices.code / devices.protocol - 'DEPO_01' and 'text'; text devices have no LoRa address
--   * telemetry.level_pct            - the raw percentage (level_mm is derived from capacity_mm)
--   * ingest_tokens                  - sha256 of each gateway token, revocable
--   * issue_ingest_token()           - SQL Editor only; returns the token once
--   * ingest_tank_reading()          - service_role only (called by the Edge Function)
--   * tank_readings                  - view in the shape agreed with the hardware side
--   * text devices take no commands (the node only sends)

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------
alter table public.devices
  add column code text unique check (code is null or code ~ '^DEPO_[A-Za-z0-9]{1,24}$'),
  add column protocol text not null default 'v1' check (protocol in ('v1', 'text')),
  alter column address drop not null,
  add constraint devices_protocol_identity check (
    (protocol = 'v1' and address is not null) or (protocol = 'text' and code is not null));

comment on column public.devices.code is 'Device id in the text protocol, e.g. DEPO_01';
comment on column public.devices.protocol is 'v1 = binary LoRa protocol via gateway_sync; text = ingest-tank';

-- Percent -> mm needs a tank height; a text device without one gets 1000 mm (admins
-- change it in the app as "Depo yüksekliği")
create or replace function public.default_text_capacity() returns trigger
  language plpgsql
as $$
begin
  if new.protocol = 'text' and new.capacity_mm is null then
    new.capacity_mm := 1000;
  end if;
  return new;
end
$$;

create trigger devices_text_capacity
  before insert on public.devices
  for each row execute function public.default_text_capacity();

-- ---------------------------------------------------------------------------
-- Telemetry: raw percentage
-- ---------------------------------------------------------------------------
alter table public.telemetry
  add column level_pct smallint check (level_pct is null or level_pct between 0 and 100);

-- ---------------------------------------------------------------------------
-- Commands: a text node only sends, it cannot execute anything
-- ---------------------------------------------------------------------------
create or replace function public.reject_text_device_command() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from public.devices where id = new.device_id and protocol = 'text') then
    raise exception 'Bu depo yalnızca ölçüm gönderir, komut alamaz' using errcode = 'check_violation';
  end if;
  return new;
end
$$;

create trigger commands_reject_text_device
  before insert on public.commands
  for each row execute function public.reject_text_device_command();

-- ---------------------------------------------------------------------------
-- Gateway tokens
-- ---------------------------------------------------------------------------
-- Only the hash is stored. No policies: only the security definer functions below read it.
create table public.ingest_tokens (
  id           bigint generated always as identity primary key,
  token_hash   text not null unique,                  -- hex sha256 of the token
  gateway_id   text not null check (length(gateway_id) between 1 and 64),
  label        text,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
alter table public.ingest_tokens enable row level security;
revoke all on public.ingest_tokens from public, anon, authenticated;

create or replace function public.ingest_token_hash(p_token text) returns text
  language sql immutable
as $$
  select encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
$$;

-- Run in the SQL Editor:  select public.issue_ingest_token('gw-text-01', 'Saha 1');
-- The token is shown only here; give it to the gateway over a secure channel.
-- Revoke:  update public.ingest_tokens set revoked_at = now() where id = ...;
create or replace function public.issue_ingest_token(p_gateway_id text, p_label text default null)
  returns text
  language plpgsql security definer set search_path = public
as $$
declare
  token text;
begin
  if auth.uid() is not null or public.is_gateway() then
    raise exception 'Tokens are issued from the SQL Editor only' using errcode = 'insufficient_privilege';
  end if;
  -- two v4 UUIDs: 244 random bits
  token := 'lwm_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.ingest_tokens (token_hash, gateway_id, label)
  values (public.ingest_token_hash(token), p_gateway_id, p_label);
  return token;
end
$$;
revoke execute on function public.issue_ingest_token(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Ingest (called by the ingest-tank Edge Function with the service_role key)
-- ---------------------------------------------------------------------------
-- Returns {"status": "ok", "id": n} | {"status": "duplicate"} | {"status": "unauthorized"}
--       | {"status": "unknown_device"}. Invalid values raise invalid_parameter_value.
-- received_at is the server time (the gateway clock is not trusted).
-- p_request_id makes resends idempotent per gateway.
create or replace function public.ingest_tank_reading(
  p_token text,
  p_code text,
  p_level_pct integer,
  p_valve text,
  p_request_id text default null
)
  returns jsonb
  language plpgsql security definer set search_path = public
as $$
declare
  gw text;
  dev public.devices;
  new_id bigint;
begin
  if p_level_pct is null or p_level_pct not between 0 and 100 then
    raise exception 'level_percent must be 0..100' using errcode = 'invalid_parameter_value';
  end if;
  if p_valve is null or p_valve not in ('ACIK', 'KAPALI') then
    raise exception 'valve_state must be ACIK or KAPALI' using errcode = 'invalid_parameter_value';
  end if;
  if p_request_id is not null and p_request_id !~ '^[A-Za-z0-9:_-]{1,64}$' then
    raise exception 'request_id must match [A-Za-z0-9:_-]{1,64}' using errcode = 'invalid_parameter_value';
  end if;

  update public.ingest_tokens
     set last_used_at = now()
   where token_hash = public.ingest_token_hash(coalesce(p_token, '')) and revoked_at is null
  returning gateway_id into gw;
  if gw is null then
    return jsonb_build_object('status', 'unauthorized');
  end if;

  -- The call proves the gateway is alive (Profil: "Gateway bağlı")
  insert into public.gateways as g (id, last_seen) values (gw, now())
  on conflict (id) do update set last_seen = excluded.last_seen;

  select * into dev from public.devices where code = p_code and protocol = 'text';
  if not found then
    return jsonb_build_object('status', 'unknown_device');
  end if;

  insert into public.telemetry (device_id, level_mm, level_pct, valve, ingest_key)
  values (dev.id,
          round(p_level_pct * dev.capacity_mm / 100.0)::integer,
          p_level_pct,
          case p_valve when 'ACIK' then 1 else 0 end,
          case when p_request_id is not null then 'text:' || gw || ':' || p_request_id end)
  on conflict (ingest_key) where ingest_key is not null do nothing
  returning id into new_id;

  if new_id is null then
    return jsonb_build_object('status', 'duplicate');
  end if;
  return jsonb_build_object('status', 'ok', 'id', new_id);
end
$$;
revoke execute on function public.ingest_tank_reading(text, text, integer, text, text) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.ingest_tank_reading(text, text, integer, text, text) to service_role;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- tank_readings: the table agreed with the hardware side, as a view
-- ---------------------------------------------------------------------------
create view public.tank_readings
  with (security_invoker = true)
as
select t.id, d.code as device_id, t.level_pct as level_percent,
       case t.valve when 1 then 'ACIK' when 0 then 'KAPALI' end as valve_state,
       t.received_at
  from public.telemetry t
  join public.devices d on d.id = t.device_id
 where d.protocol = 'text';

grant select on public.tank_readings to authenticated;

-- ---------------------------------------------------------------------------
-- Device overview: + code, protocol
-- ---------------------------------------------------------------------------
drop view if exists public.device_overview;

create view public.device_overview
  with (security_invoker = true)
as
select d.id, d.address, d.code, d.protocol, d.name, d.type, d.fw, d.period_s, d.enabled, d.capacity_mm,
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
