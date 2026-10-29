-- LoRa Water Management System - fields the mobile design needs (mobile/MOBILE-DESIGN.md,
-- "Backend needs from this design")
--
--   * devices.capacity_mm  - tank height for "Doluluk %62"; admin-only, like the thresholds
--   * devices.enabled      - follows CIHAZ_ETKIN once the device confirms it (status done)
--   * profiles.is_system   - the gateway's account (app_metadata.role = 'gateway'), shown
--                            as a non-editable system account
--   * commands.sent_at / delivered_at / finished_at - per-step times for the timeline,
--     stamped by the database on each status change (clients cannot set them)
--   * device_overview gains capacity_mm and enabled

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------
alter table public.devices
  add column capacity_mm integer check (capacity_mm is null or capacity_mm between 1 and 100000),
  add column enabled boolean not null default true;

comment on column public.devices.capacity_mm is 'Tank height in mm (gauge scale); null = unknown';
comment on column public.devices.enabled is 'Last confirmed CIHAZ_ETKIN state; true until a command says otherwise';

-- capacity_mm counts as a threshold (admin only); enabled is device state (gateway only)
create or replace function public.guard_device_update() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  rest public.devices;
begin
  if auth.uid() is null then
    return new;
  end if;

  if (new.level_low_mm, new.level_high_mm, new.pressure_low_cbar, new.pressure_high_cbar,
      new.offline_after_s, new.level_hysteresis_mm, new.pressure_hysteresis_cbar, new.capacity_mm)
     is distinct from
     (old.level_low_mm, old.level_high_mm, old.pressure_low_cbar, old.pressure_high_cbar,
      old.offline_after_s, old.level_hysteresis_mm, old.pressure_hysteresis_cbar, old.capacity_mm)
     and not public.has_role('admin') then
    raise exception 'Only an admin can change alarm thresholds'
      using errcode = 'insufficient_privilege';
  end if;

  rest := new;
  rest.name := old.name;
  rest.level_low_mm := old.level_low_mm;
  rest.level_high_mm := old.level_high_mm;
  rest.pressure_low_cbar := old.pressure_low_cbar;
  rest.pressure_high_cbar := old.pressure_high_cbar;
  rest.offline_after_s := old.offline_after_s;
  rest.level_hysteresis_mm := old.level_hysteresis_mm;
  rest.pressure_hysteresis_cbar := old.pressure_hysteresis_cbar;
  rest.capacity_mm := old.capacity_mm;
  if rest is distinct from old and not public.is_gateway() then
    raise exception 'Only the gateway can change device state columns'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end
$$;

-- When CIHAZ_ETKIN completes successfully, store the confirmed state
-- (same pattern as apply_period_command for PERIYOT_AYARLA)
create or replace function public.apply_enabled_command() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  if new.op = 'CIHAZ_ETKIN' and new.status = 'done' and old.status is distinct from 'done' then
    update public.devices
       set enabled = (new.args ->> 'enabled')::boolean
     where id = new.device_id;
  end if;
  return new;
end
$$;

create trigger commands_apply_enabled
  after update on public.commands
  for each row execute function public.apply_enabled_command();

-- ---------------------------------------------------------------------------
-- System accounts
-- ---------------------------------------------------------------------------
alter table public.profiles add column is_system boolean not null default false;
comment on column public.profiles.is_system is 'Machine account (the gateway); not a person, role not editable in the app';

-- Supabase keeps app_metadata in auth.users.raw_app_meta_data (the test stub adds it too)
create or replace function public.sync_profile_system_flag() returns trigger
  language plpgsql security definer set search_path = public
as $$
begin
  update public.profiles
     set is_system = coalesce(new.raw_app_meta_data ->> 'role', '') = 'gateway'
   where id = new.id
     and is_system is distinct from (coalesce(new.raw_app_meta_data ->> 'role', '') = 'gateway');
  return new;
end
$$;

-- after on_auth_user_created (trigger names fire in alphabetical order), so the profile exists
create trigger on_auth_user_system_flag
  after insert or update of raw_app_meta_data on auth.users
  for each row execute function public.sync_profile_system_flag();

update public.profiles p
   set is_system = true
  from auth.users u
 where u.id = p.id and u.raw_app_meta_data ->> 'role' = 'gateway';

-- is_system is derived: nobody changes it through the API, and a system account's role is fixed
create or replace function public.guard_profile_update() returns trigger
  language plpgsql security definer set search_path = public
as $$
declare
  allowed public.profiles;
begin
  if auth.uid() is not null then
    if new.is_system is distinct from old.is_system then
      raise exception 'is_system is managed by the server' using errcode = 'insufficient_privilege';
    end if;
    if old.is_system and new.role is distinct from old.role then
      raise exception 'The role of a system account cannot be changed' using errcode = 'insufficient_privilege';
    end if;
  end if;

  if auth.uid() is not null and not public.has_role('admin') then
    allowed := new;
    allowed.full_name := old.full_name;
    if allowed is distinct from old then
      raise exception 'Only an admin can change roles'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if old.role = 'admin' and new.role <> 'admin'
     and not exists (select 1 from public.profiles where role = 'admin' and id <> old.id) then
    raise exception 'At least one admin must remain'
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- Command step times
-- ---------------------------------------------------------------------------
alter table public.commands
  add column sent_at      timestamptz,
  add column delivered_at timestamptz,
  add column finished_at  timestamptz;

-- Always derived from the status change, never from the request body. A late correction
-- (failed -> done) moves finished_at to the time of the correction.
create or replace function public.stamp_command_steps() returns trigger
  language plpgsql set search_path = public
as $$
begin
  new.sent_at := old.sent_at;
  new.delivered_at := old.delivered_at;
  new.finished_at := old.finished_at;
  if new.status is distinct from old.status then
    case new.status
      when 'sent' then
        new.sent_at := coalesce(old.sent_at, now());
      when 'delivered' then
        new.sent_at := coalesce(old.sent_at, now());
        new.delivered_at := coalesce(old.delivered_at, now());
      when 'done', 'failed', 'expired' then
        new.finished_at := now();
      else
        null;
    end case;
  end if;
  return new;
end
$$;

-- Runs after commands_guard (alphabetical), so only valid transitions get stamped
create trigger commands_stamp
  before update on public.commands
  for each row execute function public.stamp_command_steps();

-- Finished rows from before this migration: updated_at is the best known finish time
update public.commands set finished_at = updated_at
 where status in ('done', 'failed', 'expired') and finished_at is null;

-- ---------------------------------------------------------------------------
-- Device overview: + capacity_mm, enabled
-- ---------------------------------------------------------------------------
drop view if exists public.device_overview;

create view public.device_overview
  with (security_invoker = true)
as
select d.id, d.address, d.name, d.type, d.fw, d.period_s, d.enabled, d.capacity_mm,
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
