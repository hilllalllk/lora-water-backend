// Edge Function: send-alert-push
//
// Called by a Database Webhook on INSERT into public.alerts, and again by the
// retry_alert_notifications() pg_cron job for alerts whose push failed. Only the alert id
// is taken from the request; the alert itself is read from the database.
//
// Outbox flow (migration 20261102000300_alert_robustness.sql):
//   claim_alert_notification(id)  -> nothing when already sent, suppressed or being sent
//   send to every registered phone (public.push_tokens)
//   finish_alert_notification(id, ok) -> ok=false releases the alert for the retry job
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
import { buildMessages, type ClaimedAlert, sendToExpo } from './push.ts';

interface WebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  schema: string;
  record: { id?: number } | null;
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
  const alertId = payload.record?.id;
  if (payload.type !== 'INSERT' || payload.table !== 'alerts' || typeof alertId !== 'number') {
    return json({ skipped: true });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  const { data: claimed, error: claimError } = await supabase
    .rpc('claim_alert_notification', { p_id: alertId });
  if (claimError) return json({ error: claimError.message }, 500);
  const alert = (claimed as ClaimedAlert[] | null)?.[0];
  if (!alert) return json({ skipped: true, reason: 'already sent, suppressed or in progress' });

  const finish = (ok: boolean, error: string | null = null) =>
    supabase.rpc('finish_alert_notification', { p_id: alert.id, p_ok: ok, p_error: error });

  try {
    const { data: tokens, error } = await supabase.from('push_tokens').select('token');
    if (error) throw new Error(`push_tokens: ${error.message}`);
    if (!tokens || tokens.length === 0) {
      await finish(true);
      return json({ sent: 0 });
    }

    const outcome = await sendToExpo(
      buildMessages(alert, tokens.map((t) => t.token as string)),
      { accessToken: Deno.env.get('EXPO_ACCESS_TOKEN') },
    );

    // Forget tokens of uninstalled apps
    if (outcome.invalid.length > 0) {
      await supabase.from('push_tokens').delete().in('token', outcome.invalid);
    }

    if (outcome.retryableError) {
      await finish(false, outcome.retryableError);
      return json({ sent: outcome.sent, retry: true, error: outcome.retryableError }, 502);
    }
    await finish(true);
    return json({ sent: outcome.sent, removed: outcome.invalid.length });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await finish(false, message);
    return json({ error: message }, 500);
  }
});
