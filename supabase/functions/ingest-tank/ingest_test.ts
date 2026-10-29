// deno test backend/supabase/functions/ingest-tank/ingest_test.ts
// The acceptance checks of the hardware hand-off (docs/05-kurulum.md) at the HTTP level.
import { assertEquals } from 'jsr:@std/assert@1';
import { handle, type IngestRpc, parseReading, type Reading, type RpcResult } from './ingest.ts';

const good = { device_id: 'DEPO_01', level_percent: 75, valve_state: 'KAPALI' };

function post(body: unknown, headers: Record<string, string> = { 'X-Device-Token': 't' }): Request {
  return new Request('http://x/ingest-tank', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

function fakeRpc(result: RpcResult | Error) {
  const calls: Array<{ token: string; r: Reading }> = [];
  const rpc: IngestRpc = (token, r) => {
    calls.push({ token, r });
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result);
  };
  return { rpc, calls };
}

Deno.test('stores a valid reading: 201', async () => {
  const { rpc, calls } = fakeRpc({ status: 'ok', id: 9 });
  const res = await handle(post(good, { 'X-Device-Token': 'secret', 'X-Request-Id': 'a1-7' }), rpc);
  assertEquals(res.status, 201);
  assertEquals(await res.json(), { ok: true, id: 9 });
  assertEquals(calls[0], { token: 'secret', r: { ...good, valve_state: 'KAPALI', request_id: 'a1-7' } });
});

Deno.test('a resend is 200, not an error', async () => {
  const res = await handle(post(good), fakeRpc({ status: 'duplicate' }).rpc);
  assertEquals(res.status, 200);
});

Deno.test('wrong or missing token: 401, the database is not called without one', async () => {
  assertEquals((await handle(post(good), fakeRpc({ status: 'unauthorized' }).rpc)).status, 401);
  const { rpc, calls } = fakeRpc({ status: 'ok', id: 1 });
  assertEquals((await handle(post(good, {}), rpc)).status, 401);
  assertEquals(calls.length, 0);
});

Deno.test('invalid level, valve, id or JSON: 400', async () => {
  const { rpc, calls } = fakeRpc({ status: 'ok', id: 1 });
  for (const body of [
    { ...good, level_percent: 150 },
    { ...good, level_percent: -1 },
    { ...good, level_percent: 7.5 },
    { ...good, level_percent: '75' },
    { ...good, valve_state: 'acik' },
    { ...good, device_id: 'TANK_01' },
    { ...good, device_id: 'DEPO_' },
    { ...good, request_id: 'has space' },
    [good],
    'not json',
  ]) {
    assertEquals((await handle(post(body), rpc)).status, 400, JSON.stringify(body));
  }
  assertEquals(calls.length, 0);
});

Deno.test('unknown device: 404; database error: 500', async () => {
  assertEquals((await handle(post(good), fakeRpc({ status: 'unknown_device' }).rpc)).status, 404);
  assertEquals((await handle(post(good), fakeRpc(new Error('down')).rpc)).status, 500);
});

Deno.test('GET: 405; large body: 413', async () => {
  const rpc = fakeRpc({ status: 'ok', id: 1 }).rpc;
  assertEquals((await handle(new Request('http://x/ingest-tank'), rpc)).status, 405);
  assertEquals((await handle(post({ ...good, pad: 'x'.repeat(2000) }), rpc)).status, 413);
});

Deno.test('request_id from the body when there is no header', () => {
  assertEquals((parseReading({ ...good, request_id: 'b-2' }, null) as Reading).request_id, 'b-2');
  assertEquals((parseReading(good, null) as Reading).request_id, null);
});
