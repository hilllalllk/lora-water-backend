// Edge Function: send-alert-push
//
// Called by a Database Webhook on INSERT into public.alerts. Sends an Expo push
// notification for the new alert to every registered phone (public.push_tokens).
//
// Environment (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically
// on Supabase; the service role key stays on the server):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   WEBHOOK_SECRET     required; requests must send it in header x-webhook-secret
//                      (the function is deployed with --no-verify-jwt, so this is its only guard)
//   EXPO_ACCESS_TOKEN  optional; only if "enhanced push security" is enabled in Expo
//
// Deploy: see backend/README.md "Push notifications".

import { createClient } from 'jsr:@supabase/supabase-js@2';

const EXPO_PUSH_URL = 'https://exp.host/--/api/v2/push/send';
const CHUNK_SIZE = 100; // Expo accepts at most 100 messages per request

interface AlertRow {
  id: number;
  device_id: string;
  kind: string;
  message: string;
  value: number | null;
  created_at: string;
  resolved_at: string | null;
}

interface WebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  schema: string;
  record: AlertRow | null;
  old_record: AlertRow | null;
}

interface ExpoTicket {
  status: 'ok' | 'error';
  id?: string;
  message?: string;
  details?: { error?: string };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  // Fail closed: without a configured secret anyone could trigger notifications.
  const secret = Deno.env.get('WEBHOOK_SECRET');
  if (!secret) return json({ error: 'WEBHOOK_SECRET is not configured' }, 500);
  if (req.headers.get('x-webhook-secret') !== secret) {
    return json({ error: 'unauthorized' }, 401);
  }

  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'invalid json' }, 400);
  }
  const alert = payload.record;
  if (payload.type !== 'INSERT' || payload.table !== 'alerts' || !alert) {
    return json({ skipped: true });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  const { data: device } = await supabase
    .from('devices')
    .select('name')
    .eq('id', alert.device_id)
    .maybeSingle();
  const deviceName = device?.name ?? alert.device_id;

  const { data: tokens, error } = await supabase.from('push_tokens').select('token');
  if (error) return json({ error: error.message }, 500);
  if (!tokens || tokens.length === 0) return json({ sent: 0 });

  const messages = tokens.map(({ token }) => ({
    to: token,
    title: `Alarm: ${deviceName}`,
    body: alert.message,
    sound: 'default',
    priority: 'high',
    channelId: 'alarms', // created by the app on Android
    data: { alertId: alert.id, deviceId: alert.device_id, kind: alert.kind },
  }));

  const headers: Record<string, string> = {
    Accept: 'application/json',
    'Accept-Encoding': 'gzip, deflate',
    'Content-Type': 'application/json',
  };
  const expoToken = Deno.env.get('EXPO_ACCESS_TOKEN');
  if (expoToken) headers.Authorization = `Bearer ${expoToken}`;

  let sent = 0;
  const invalid: string[] = [];
  for (let i = 0; i < messages.length; i += CHUNK_SIZE) {
    const chunk = messages.slice(i, i + CHUNK_SIZE);
    const res = await fetch(EXPO_PUSH_URL, { method: 'POST', headers, body: JSON.stringify(chunk) });
    if (!res.ok) {
      console.error('Expo push error', res.status, await res.text());
      continue;
    }
    const { data: tickets } = (await res.json()) as { data: ExpoTicket[] };
    tickets.forEach((ticket, j) => {
      if (ticket.status === 'ok') sent++;
      else if (ticket.details?.error === 'DeviceNotRegistered') invalid.push(chunk[j].to);
      else console.error('Expo ticket error', ticket.message);
    });
  }

  // Forget tokens of uninstalled apps
  if (invalid.length > 0) {
    await supabase.from('push_tokens').delete().in('token', invalid);
  }

  return json({ sent, removed: invalid.length });
});
