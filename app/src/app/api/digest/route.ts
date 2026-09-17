import { createClient as createSupabaseClient } from '@supabase/supabase-js';
import { requireSupabaseEnv } from '@/lib/env';
import {
  formatForPerson, formatForWhatsApp, normaliseIndianNumber,
  readWhatsAppConfig, sendWhatsApp, type Digest,
} from '@/lib/digest';

/**
 * The 6pm end-of-day digest.
 *
 * Fired by Vercel Cron (see vercel.json) at 12:30 UTC, which is 18:00 IST.
 * Cron does not carry a user session, so this uses the anon key plus the
 * digest secret that unlocks one read-only SQL function — not the service_role
 * key, which would bypass row-level security for the whole database in order
 * to read a list of task names.
 *
 * Always returns the formatted text. That matters: until WhatsApp API
 * credentials exist, /digest renders this for one-tap pasting into the group,
 * so the 6pm message happens either way.
 *
 * If N8N_WEBHOOK_URL is set, the group text is also POSTed there -- an n8n
 * workflow forwards it into the actual WhatsApp group. That indirection
 * exists because Meta's own Business API cannot post to a group at all
 * (only to individuals), so group delivery necessarily goes through an
 * unofficial provider that lives in n8n, not in this app.
 */

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

function authorised(req: Request): boolean {
  const secret = process.env.CRON_SECRET;
  // Vercel Cron sends `Authorization: Bearer <CRON_SECRET>`.
  if (!secret) return false;
  const header = req.headers.get('authorization') ?? '';
  return header === `Bearer ${secret}`;
}

export async function GET(req: Request) {
  if (!authorised(req)) {
    return Response.json({ ok: false, error: 'Not authorised' }, { status: 401 });
  }

  const digestSecret = process.env.DIGEST_SECRET;
  if (!digestSecret) {
    return Response.json(
      { ok: false, error: 'DIGEST_SECRET is not set. Copy it from app_settings.' },
      { status: 500 },
    );
  }

  const env = requireSupabaseEnv();
  const supabase = createSupabaseClient(env.url, env.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await supabase.rpc('daily_digest', { p_secret: digestSecret });
  if (error) {
    return Response.json({ ok: false, error: error.message }, { status: 500 });
  }

  const digest = data as Digest;
  const appUrl = process.env.NEXT_PUBLIC_APP_URL
    ?? 'https://shardacare-healthcity.vercel.app';

  const groupText = formatForWhatsApp(digest, `${appUrl}/work?filter=active`);

  // In-app notification for everyone, always. This is the delivery that cannot
  // fail for want of a third-party credential -- so if it errors (e.g.
  // DIGEST_SECRET has drifted from app_settings across environments), that
  // must surface rather than be reported as a quiet "0 notified".
  const { data: notified, error: notifyError } = await supabase.rpc('record_digest_sent', {
    p_secret: digestSecret,
    p_summary: groupText,
  });
  if (notifyError) {
    console.error('daily digest: record_digest_sent failed', notifyError);
  }

  // Direct WhatsApp, per person, where that is configured.
  const cfg = readWhatsAppConfig();
  const sent: string[] = [];
  const failed: { name: string; error: string }[] = [];

  if (cfg) {
    for (const r of digest.recipients) {
      const to = normaliseIndianNumber(r.phone);
      if (!to) continue;

      const personal = formatForPerson(digest, r.user_id, `${appUrl}/my-work`);
      const result = await sendWhatsApp(cfg, to, personal ?? groupText);

      if (result.ok) sent.push(r.name);
      else failed.push({ name: r.name, error: result.error ?? 'unknown' });
    }
  }

  // Hand the group message off to n8n, which owns the actual WhatsApp-group
  // delivery (Meta's own Business API cannot post to a group at all, so that
  // side is necessarily an n8n workflow talking to an unofficial provider,
  // not this app). Best-effort: a webhook outage should not fail the digest
  // itself -- the /digest page and in-app notification above already cover
  // delivery -- but the failure must be visible, not swallowed.
  const n8nWebhookUrl = process.env.N8N_WEBHOOK_URL;
  let n8n: { configured: boolean; ok?: boolean; error?: string } = { configured: false };

  if (n8nWebhookUrl) {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10_000);
      const res = await fetch(n8nWebhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          date: digest.date,
          counts: digest.totals ?? {},
          items: digest.items.length,
          groupText,
        }),
        signal: controller.signal,
      });
      clearTimeout(timeout);
      n8n = res.ok
        ? { configured: true, ok: true }
        : { configured: true, ok: false, error: `n8n webhook returned ${res.status}` };
    } catch (err) {
      n8n = {
        configured: true,
        ok: false,
        error: err instanceof Error ? err.message : 'n8n webhook request failed',
      };
    }
    if (!n8n.ok) console.error('daily digest: n8n webhook failed', n8n.error);
  }

  return Response.json({
    ok: true,
    date: digest.date,
    counts: digest.totals ?? {},
    items: digest.items.length,
    inAppNotified: notified ?? 0,
    inAppNotifyError: notifyError?.message ?? null,
    whatsapp: cfg
      ? { configured: true, sent, failed }
      : {
          configured: false,
          note:
            'WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID are not set, so no direct ' +
            'messages were sent. The digest text below is ready to paste into the group.',
        },
    n8n: n8nWebhookUrl
      ? n8n
      : { configured: false, note: 'N8N_WEBHOOK_URL is not set, so the group message was not forwarded.' },
    groupText,
  });
}
