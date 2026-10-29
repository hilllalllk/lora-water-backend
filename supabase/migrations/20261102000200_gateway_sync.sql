-- LoRa Water Management System - one round trip per gateway cycle
--
-- The old gateway made up to five separate HTTPS requests (telemetry, heartbeat, command
-- status, health, claim), each with its own TLS handshake, while the LoRa receiver was
-- blocked. public.gateway_sync() does all of it in one call. Every part is applied on its
-- own: a bad row or report is listed in "errors" and never fails the whole call, so the
-- gateway can drop exactly what was accepted from its queue.
--
-- Request (every key optional):
--   {
--     "gateway_id": "gw-1",                                     -- required
--     "telemetry": [ ...rows as in ingest_telemetry(), max 100... ],
--     "seen":      [ {"address": 4097, "fw": "1.2.0", "at": "2026-11-02T10:00:00Z"} ],
--     "reports":   [ {"id": 42, "status": "delivered", "result": null} ],
--     "health":    { "fw": "1.2.0", "wifi_rssi": -61, "heap_free": 81234, "heap_min": 60211,
--                    "uptime_s": 3600, "reset_reason": "poweron", "queue_len": 0, "dropped": 0 },
--     "claim": true                                             -- false while a command is in flight
--   }
-- Response:
--   {
--     "ingest":  {"inserted": n, "duplicates": n, "skipped": n} | null,
--     "reports": [ {"id": 42, "outcome": "ok|noop|rejected|unknown"} ],
--     "command": {"id": 43, "address": 4097, "op": "VANA_AC", "args": null} | null,
--     "poll_ms": 1000 | 3000,
--     "errors":  [ {"part": "telemetry", "message": "..."} ]
--   }

-- ---------------------------------------------------------------------------
-- Gateway health columns
-- ---------------------------------------------------------------------------
alter table public.gateways
  add column heap_free     integer,
  add column heap_min      integer,
  add column uptime_s      integer,
  add column reset_reason  text,
  add column queue_len     integer,
  add column dropped       integer,
  add column last_error    text;

-- ---------------------------------------------------------------------------
-- Node heartbeats by address
-- ---------------------------------------------------------------------------
-- p_seen: [{"address": 4097, "fw": "1.2.0", "at": "..."}]. last_seen only moves forward
-- and never past now(). Returns the number of devices updated.
create or replace function public.mark_devices_seen(p_seen jsonb)
  returns integer
  language plpgsql security invoker set search_path = public
as $$
declare
  n integer;
begin
  if not public.is_gateway() then
    raise exception 'Only the gateway can mark devices seen' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_seen) is distinct from 'array' then
    raise exception 'p_seen must be a JSON array' using errcode = 'invalid_parameter_value';
  end if;

  update public.devices d
     set last_seen = greatest(d.last_seen, s.at),
         fw = coalesce(s.fw, d.fw)
    from (
      select x.address, max(least(coalesce(x.at, now()), now())) as at, max(x.fw) as fw
        from jsonb_to_recordset(p_seen) as x(address integer, fw text, at timestamptz)
       group by x.address
    ) s
   where d.address = s.address;
  get diagnostics n = row_count;
  return n;
end
$$;
revoke execute on function public.mark_devices_seen(jsonb) from public, anon;
grant execute on function public.mark_devices_seen(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- The sync call
-- ---------------------------------------------------------------------------
create or replace function public.gateway_sync(p jsonb)
  returns jsonb
  language plpgsql security invoker set search_path = public
as $$
declare
  gw text := p ->> 'gateway_id';
  h jsonb := p -> 'health';
  errors jsonb := '[]'::jsonb;
  ingest jsonb;
  reports jsonb := '[]'::jsonb;
  rep jsonb;
  outcome text;
  cmd jsonb;
  more_pending boolean;
begin
  if not public.is_gateway() then
    raise exception 'Only the gateway can sync' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(gw, '') = '' or length(gw) > 64 then
    raise exception 'gateway_id is required (1..64 chars)' using errcode = 'invalid_parameter_value';
  end if;

  -- 1. Telemetry
  if jsonb_typeof(p -> 'telemetry') = 'array' and jsonb_array_length(p -> 'telemetry') > 0 then
    begin
      ingest := public.ingest_telemetry(p -> 'telemetry');
    exception when others then
      errors := errors || jsonb_build_object('part', 'telemetry', 'message', sqlerrm);
    end;
  end if;

  -- 2. Node heartbeats
  if jsonb_typeof(p -> 'seen') = 'array' and jsonb_array_length(p -> 'seen') > 0 then
    begin
      perform public.mark_devices_seen(p -> 'seen');
    exception when others then
      errors := errors || jsonb_build_object('part', 'seen', 'message', sqlerrm);
    end;
  end if;

  -- 3. Command reports, each on its own
  if jsonb_typeof(p -> 'reports') = 'array' then
    for rep in select * from jsonb_array_elements(p -> 'reports') loop
      begin
        outcome := public.report_command((rep ->> 'id')::bigint,
                                         (rep ->> 'status')::public.command_status,
                                         (rep ->> 'result')::smallint);
      exception when others then
        outcome := 'rejected';
        errors := errors || jsonb_build_object('part', 'reports', 'id', rep -> 'id', 'message', sqlerrm);
      end;
      reports := reports || jsonb_build_object('id', rep -> 'id', 'outcome', outcome);
    end loop;
  end if;

  -- 4. Gateway health (always: the call itself proves the gateway is alive)
  begin
    insert into public.gateways as g
           (id, fw, wifi_rssi, last_seen, heap_free, heap_min, uptime_s, reset_reason,
            queue_len, dropped, last_error)
    values (gw, h ->> 'fw', (h ->> 'wifi_rssi')::integer, now(), (h ->> 'heap_free')::integer,
            (h ->> 'heap_min')::integer, (h ->> 'uptime_s')::integer, h ->> 'reset_reason',
            (h ->> 'queue_len')::integer, (h ->> 'dropped')::integer, h ->> 'last_error')
    on conflict (id) do update set
      fw = coalesce(excluded.fw, g.fw),
      wifi_rssi = coalesce(excluded.wifi_rssi, g.wifi_rssi),
      last_seen = excluded.last_seen,
      heap_free = coalesce(excluded.heap_free, g.heap_free),
      heap_min = coalesce(excluded.heap_min, g.heap_min),
      uptime_s = coalesce(excluded.uptime_s, g.uptime_s),
      reset_reason = coalesce(excluded.reset_reason, g.reset_reason),
      queue_len = coalesce(excluded.queue_len, g.queue_len),
      dropped = coalesce(excluded.dropped, g.dropped),
      last_error = coalesce(excluded.last_error, g.last_error);
  exception when others then
    errors := errors || jsonb_build_object('part', 'health', 'message', sqlerrm);
  end;

  -- 5. Next command
  if coalesce((p ->> 'claim')::boolean, true) then
    begin
      select to_jsonb(c) into cmd from public.lease_next_command(gw) c;
      cmd := cmd - 'device_id';
    exception when others then
      errors := errors || jsonb_build_object('part', 'claim', 'message', sqlerrm);
    end;
  end if;

  -- Poll faster while commands are waiting, so a queue drains quickly
  select exists (select 1 from public.commands
                  where status = 'pending' and expires_at > now()
                    and (lease_until is null or lease_until <= now()))
    into more_pending;

  return jsonb_build_object(
    'ingest', ingest,
    'reports', reports,
    'command', cmd,
    'poll_ms', case when cmd is not null or more_pending then 1000 else 3000 end,
    'errors', errors
  );
end
$$;
revoke execute on function public.gateway_sync(jsonb) from public, anon;
grant execute on function public.gateway_sync(jsonb) to authenticated;
