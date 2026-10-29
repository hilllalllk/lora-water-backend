// deno test backend/supabase/functions/send-alert-push/push_test.ts
import { assertEquals, assertMatch } from 'jsr:@std/assert@1';
import { buildMessages, type ClaimedAlert, sendToExpo } from './push.ts';

const alert: ClaimedAlert = {
  id: 7,
  kind: 'level_high',
  message: 'Depo seviyesi yüksek',
  device_id: 'node-1001',
  gateway_id: null,
  subject_name: 'Depo-1',
  created_at: '2026-11-02T10:00:00Z',
};

function fakeFetch(responses: Array<Response | Error>): { fetchFn: typeof fetch; calls: number } {
  const state = { calls: 0, fetchFn: (() => {}) as unknown as typeof fetch };
  state.fetchFn = (() => {
    const r = responses[state.calls++];
    return r instanceof Error ? Promise.reject(r) : Promise.resolve(r);
  }) as typeof fetch;
  return state;
}

const tickets = (...t: unknown[]) => new Response(JSON.stringify({ data: t }), { status: 200 });

Deno.test('builds one message per token with device and gateway titles', () => {
  const msgs = buildMessages(alert, ['a', 'b']);
  assertEquals(msgs.length, 2);
  assertEquals(msgs[0].title, 'Alarm: Depo-1');
  assertEquals(msgs[1].data.alertId, 7);
  const gw = buildMessages({ ...alert, device_id: null, gateway_id: 'gw-1', subject_name: 'gw-1' }, ['a']);
  assertEquals(gw[0].title, 'Gateway: gw-1');
});

Deno.test('counts sent tickets and collects uninstalled tokens', async () => {
  const f = fakeFetch([tickets({ status: 'ok' }, { status: 'error', details: { error: 'DeviceNotRegistered' } })]);
  const out = await sendToExpo(buildMessages(alert, ['a', 'b']), { fetchFn: f.fetchFn });
  assertEquals(out, { sent: 1, invalid: ['b'], retryableError: null });
});

Deno.test('splits into chunks of 100', async () => {
  const ok = Array.from({ length: 100 }, () => ({ status: 'ok' }));
  const f = fakeFetch([tickets(...ok), tickets({ status: 'ok' })]);
  const out = await sendToExpo(buildMessages(alert, Array.from({ length: 101 }, (_, i) => `t${i}`)), { fetchFn: f.fetchFn });
  assertEquals(f.calls, 2);
  assertEquals(out.sent, 101);
});

Deno.test('5xx, 429 and network errors are retryable; other 4xx are not', async () => {
  for (const r of [new Response('busy', { status: 503 }), new Response('slow down', { status: 429 }), new Error('timeout')]) {
    const out = await sendToExpo(buildMessages(alert, ['a']), { fetchFn: fakeFetch([r]).fetchFn });
    assertMatch(out.retryableError ?? '', /Expo/);
  }
  const bad = await sendToExpo(buildMessages(alert, ['a']), { fetchFn: fakeFetch([new Response('no', { status: 400 })]).fetchFn });
  assertEquals(bad.retryableError, null);
});
