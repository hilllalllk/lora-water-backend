// Pure push logic for send-alert-push, kept apart from Deno.serve so it can be unit tested
// with a fake fetch (push_test.ts).

export const EXPO_PUSH_URL = 'https://exp.host/--/api/v2/push/send';
export const CHUNK_SIZE = 100; // Expo accepts at most 100 messages per request
export const EXPO_TIMEOUT_MS = 10_000;

// Row returned by public.claim_alert_notification()
export interface ClaimedAlert {
  id: number;
  kind: string;
  message: string;
  device_id: string | null;
  gateway_id: string | null;
  subject_name: string;
  created_at: string;
}

export interface PushMessage {
  to: string;
  title: string;
  body: string;
  sound: 'default';
  priority: 'high';
  channelId: string;
  data: Record<string, unknown>;
}

interface ExpoTicket {
  status: 'ok' | 'error';
  id?: string;
  message?: string;
  details?: { error?: string };
}

export interface SendOutcome {
  sent: number;
  // Tokens Expo reports as uninstalled; the caller deletes them
  invalid: string[];
  // Set when at least one chunk could not be delivered to Expo (network, 429, 5xx).
  // The alert then stays unsent and the retry job tries again.
  retryableError: string | null;
}

export function buildMessages(alert: ClaimedAlert, tokens: string[]): PushMessage[] {
  const title = alert.gateway_id ? `Gateway: ${alert.subject_name}` : `Alarm: ${alert.subject_name}`;
  return tokens.map((to) => ({
    to,
    title,
    body: alert.message,
    sound: 'default',
    priority: 'high',
    channelId: 'alarms', // created by the app on Android
    data: { alertId: alert.id, deviceId: alert.device_id, gatewayId: alert.gateway_id, kind: alert.kind },
  }));
}

export async function sendToExpo(
  messages: PushMessage[],
  opts: { accessToken?: string; fetchFn?: typeof fetch; timeoutMs?: number } = {},
): Promise<SendOutcome> {
  const fetchFn = opts.fetchFn ?? fetch;
  const headers: Record<string, string> = {
    Accept: 'application/json',
    'Accept-Encoding': 'gzip, deflate',
    'Content-Type': 'application/json',
  };
  if (opts.accessToken) headers.Authorization = `Bearer ${opts.accessToken}`;

  const outcome: SendOutcome = { sent: 0, invalid: [], retryableError: null };
  for (let i = 0; i < messages.length; i += CHUNK_SIZE) {
    const chunk = messages.slice(i, i + CHUNK_SIZE);
    let res: Response;
    try {
      res = await fetchFn(EXPO_PUSH_URL, {
        method: 'POST',
        headers,
        body: JSON.stringify(chunk),
        signal: AbortSignal.timeout(opts.timeoutMs ?? EXPO_TIMEOUT_MS),
      });
    } catch (e) {
      outcome.retryableError = `Expo request failed: ${e instanceof Error ? e.message : String(e)}`;
      continue;
    }
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      const msg = `Expo HTTP ${res.status}: ${text.slice(0, 200)}`;
      // 4xx other than 429 will not get better by retrying
      if (res.status === 429 || res.status >= 500) outcome.retryableError = msg;
      else console.error(msg);
      continue;
    }
    let tickets: ExpoTicket[] = [];
    try {
      tickets = ((await res.json()) as { data?: ExpoTicket[] }).data ?? [];
    } catch {
      outcome.retryableError = 'Expo returned invalid JSON';
      continue;
    }
    tickets.forEach((ticket, j) => {
      if (ticket.status === 'ok') outcome.sent++;
      else if (ticket.details?.error === 'DeviceNotRegistered') outcome.invalid.push(chunk[j].to);
      else console.error('Expo ticket error', ticket.message);
    });
  }
  return outcome;
}
