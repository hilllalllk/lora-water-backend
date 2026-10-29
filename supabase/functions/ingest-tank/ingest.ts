// Request handling for ingest-tank, without Supabase or Deno.serve, so the whole contract
// is unit tested (ingest_test.ts). The database does the token check, the device lookup
// and the insert (ingest_tank_reading, migration 20261103000000_text_ingest.sql).

export const MAX_BODY = 1024;
const DEVICE_ID = /^DEPO_[A-Za-z0-9]{1,24}$/;
const REQUEST_ID = /^[A-Za-z0-9:_-]{1,64}$/;

export interface Reading {
  device_id: string;
  level_percent: number;
  valve_state: 'ACIK' | 'KAPALI';
  request_id: string | null;
}

export type RpcResult =
  | { status: 'ok'; id: number }
  | { status: 'duplicate' }
  | { status: 'unauthorized' }
  | { status: 'unknown_device' };

// Calls ingest_tank_reading; throws on a database or network error
export type IngestRpc = (token: string, r: Reading) => Promise<RpcResult>;

// Body as agreed with the hardware side:
//   {"device_id":"DEPO_01","level_percent":75,"valve_state":"KAPALI"}
// plus an optional "request_id" (or X-Request-Id header) that makes resends idempotent.
export function parseReading(body: unknown, headerRequestId: string | null): Reading | string {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return 'body must be a JSON object';
  const b = body as Record<string, unknown>;
  if (typeof b.device_id !== 'string' || !DEVICE_ID.test(b.device_id)) return 'device_id must match DEPO_<1-24 letters/digits>';
  if (!Number.isInteger(b.level_percent) || (b.level_percent as number) < 0 || (b.level_percent as number) > 100) {
    return 'level_percent must be an integer 0..100';
  }
  if (b.valve_state !== 'ACIK' && b.valve_state !== 'KAPALI') return 'valve_state must be ACIK or KAPALI';
  const requestId = headerRequestId ?? b.request_id ?? null;
  if (requestId !== null && (typeof requestId !== 'string' || !REQUEST_ID.test(requestId))) {
    return 'request_id must match [A-Za-z0-9:_-]{1,64}';
  }
  return {
    device_id: b.device_id,
    level_percent: b.level_percent as number,
    valve_state: b.valve_state,
    request_id: requestId as string | null,
  };
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

// Status codes (the gateway retries only 5xx and network errors):
//   201 stored | 200 duplicate of an earlier request_id | 400 invalid body | 401 token
//   404 unknown device | 405 not POST | 413 body too large | 500 database error
export async function handle(req: Request, rpc: IngestRpc): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const token = req.headers.get('x-device-token');
  if (!token || token.length > 200) return json({ error: 'unauthorized' }, 401);

  const length = Number(req.headers.get('content-length') ?? 0);
  if (length > MAX_BODY) return json({ error: 'body too large' }, 413);
  const text = await req.text();
  if (text.length > MAX_BODY) return json({ error: 'body too large' }, 413);

  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return json({ error: 'invalid json' }, 400);
  }
  const reading = parseReading(body, req.headers.get('x-request-id'));
  if (typeof reading === 'string') return json({ error: reading }, 400);

  let result: RpcResult;
  try {
    result = await rpc(token, reading);
  } catch (e) {
    console.error('ingest_tank_reading failed', e instanceof Error ? e.message : e);
    return json({ error: 'database error' }, 500);
  }
  switch (result.status) {
    case 'ok':
      return json({ ok: true, id: result.id }, 201);
    case 'duplicate':
      return json({ ok: true, duplicate: true }, 200);
    case 'unauthorized':
      return json({ error: 'unauthorized' }, 401);
    case 'unknown_device':
      return json({ error: `unknown device: ${reading.device_id}` }, 404);
    default:
      return json({ error: 'database error' }, 500);
  }
}
