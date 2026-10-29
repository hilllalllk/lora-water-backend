// Edge Function: ingest-tank
//
// Entry point for text protocol gateways (firmware env gateway-text, ADR-0011). The
// gateway posts each LoRa line "DEPO_01,75,KAPALI" as
//   POST /functions/v1/ingest-tank
//   X-Device-Token: <token from issue_ingest_token()>
//   X-Request-Id:   <optional, makes resends idempotent>
//   {"device_id":"DEPO_01","level_percent":75,"valve_state":"KAPALI"}
// and the reading goes into devices/telemetry like any other measurement.
//
// Environment (provided automatically on Supabase; the service role key stays on the server
// and is never given to a gateway or the app):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy (the gateway sends no JWT; the token is checked in the database):
//   npx supabase functions deploy ingest-tank --no-verify-jwt

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { handle, type RpcResult } from './ingest.ts';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve((req) =>
  handle(req, async (token, r) => {
    const { data, error } = await db.rpc('ingest_tank_reading', {
      p_token: token,
      p_code: r.device_id,
      p_level_pct: r.level_percent,
      p_valve: r.valve_state,
      p_request_id: r.request_id,
    });
    if (error) throw new Error(error.message);
    return data as RpcResult;
  })
);
