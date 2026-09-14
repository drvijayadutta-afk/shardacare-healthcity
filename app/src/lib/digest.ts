/**
 * The 6pm end-of-day digest: shaping and delivery.
 *
 * A note on "send it to the WhatsApp group", because the constraint is real
 * and shapes everything here: the official WhatsApp Cloud API and every
 * compliant reseller (Twilio, Gupshup, 360dialog) send to INDIVIDUAL numbers.
 * Meta has never exposed group messaging to the Business API. Services that
 * advertise it drive an unofficial client and get numbers banned, which is not
 * a risk worth taking with the number a hospital markets on.
 *
 * So this does the two things that are both reliable and automatic — an in-app
 * notification for everyone, and a direct WhatsApp message to each person who
 * has a number on file — and produces one formatted block that a person taps
 * once to paste into the group. Same content, three routes out.
 */

export interface DigestItem {
  bucket: string;
  work_item_id: string;
  name: string;
  stage_name: string;
  status: string;
  owner_name: string | null;
  owner_id: string | null;
  deadline: string | null;
  po_status: string;
  priority: string;
}

export interface DigestRecipient {
  user_id: string;
  name: string;
  phone: string | null;
  email: string;
}

export interface Digest {
  generated_at: string;
  date: string;
  totals: Record<string, number> | null;
  items: DigestItem[];
  recipients: DigestRecipient[];
}

const BUCKET_TITLE: Record<string, string> = {
  overdue: '🔴 Overdue',
  due_today: '🟠 Due today',
  blocked: '⏸️ Blocked / on hold',
  in_flight: '🔵 Moved today',
  completed_today: '✅ Completed today',
};

const BUCKET_ORDER = ['overdue', 'due_today', 'blocked', 'in_flight', 'completed_today'];

function stage(item: DigestItem): string {
  return item.stage_name.replace(/_/g, ' ').toLowerCase();
}

/**
 * WhatsApp text. Deliberately plain: *bold* is the only markup WhatsApp
 * renders reliably, and a message people read on a phone at 6pm has to survive
 * being skimmed in five seconds.
 */
export function formatForWhatsApp(d: Digest, appUrl: string): string {
  const date = new Date(d.date + 'T00:00:00').toLocaleDateString('en-GB', {
    weekday: 'short', day: 'numeric', month: 'short',
  });

  const lines: string[] = [`*Marketing — end of day, ${date}*`];

  const t = d.totals ?? {};
  const headline = [
    t.overdue ? `${t.overdue} overdue` : null,
    t.due_today ? `${t.due_today} due today` : null,
    t.blocked ? `${t.blocked} blocked` : null,
    t.completed_today ? `${t.completed_today} completed` : null,
  ].filter(Boolean).join(' · ');
  if (headline) lines.push(headline);

  for (const bucket of BUCKET_ORDER) {
    const items = d.items.filter((i) => i.bucket === bucket);
    if (!items.length) continue;

    lines.push('', `*${BUCKET_TITLE[bucket] ?? bucket}*`);
    // Cap each section. A 60-line WhatsApp message gets collapsed behind "Read
    // more" and stops being a glance.
    for (const i of items.slice(0, 12)) {
      const who = i.owner_name ?? 'unassigned';
      const po = i.po_status && !['NOT_REQUIRED', 'RELEASED'].includes(i.po_status)
        ? ` · PO ${i.po_status.replace(/_/g, ' ').toLowerCase()}`
        : '';
      lines.push(`• ${i.name} — ${who} · ${stage(i)}${po}`);
    }
    if (items.length > 12) lines.push(`  …and ${items.length - 12} more`);
  }

  if (!d.items.length) lines.push('', 'Nothing outstanding. 🎉');

  lines.push('', appUrl);
  return lines.join('\n');
}

/** A shorter, personal version: what YOU are holding. */
export function formatForPerson(d: Digest, userId: string, appUrl: string): string | null {
  const mine = d.items.filter((i) => i.owner_id === userId && i.bucket !== 'completed_today');
  if (!mine.length) return null;

  const date = new Date(d.date + 'T00:00:00').toLocaleDateString('en-GB', {
    day: 'numeric', month: 'short',
  });

  const lines = [`*Your work — ${date}*`];
  for (const i of mine.slice(0, 10)) {
    const flag = i.bucket === 'overdue' ? '🔴 ' : i.bucket === 'due_today' ? '🟠 ' : '';
    lines.push(`${flag}${i.name} — ${stage(i)}`);
  }
  if (mine.length > 10) lines.push(`…and ${mine.length - 10} more`);
  lines.push('', appUrl);
  return lines.join('\n');
}

/* -------------------------------------------------------------------------- */
/* WhatsApp Cloud API                                                          */
/* -------------------------------------------------------------------------- */

export interface WhatsAppConfig {
  token: string;
  phoneNumberId: string;
  /** Optional approved template name for messages outside the 24-hour window. */
  templateName?: string;
}

export function readWhatsAppConfig(): WhatsAppConfig | null {
  const token = process.env.WHATSAPP_TOKEN;
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  if (!token?.trim() || !phoneNumberId?.trim()) return null;
  return {
    token: token.trim(),
    phoneNumberId: phoneNumberId.trim(),
    templateName: process.env.WHATSAPP_TEMPLATE_NAME?.trim() || undefined,
  };
}

/** E.164 without the leading +, which is what the Cloud API expects. */
export function normaliseIndianNumber(raw: string | null): string | null {
  if (!raw) return null;
  const digits = raw.replace(/\D/g, '');
  if (!digits) return null;
  if (digits.length === 10) return `91${digits}`;          // bare Indian mobile
  if (digits.length === 12 && digits.startsWith('91')) return digits;
  if (digits.length === 11 && digits.startsWith('0')) return `91${digits.slice(1)}`;
  return digits.length >= 11 ? digits : null;
}

export async function sendWhatsApp(
  cfg: WhatsAppConfig,
  to: string,
  body: string,
): Promise<{ ok: boolean; error?: string }> {
  const res = await fetch(
    `https://graph.facebook.com/v21.0/${cfg.phoneNumberId}/messages`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${cfg.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to,
        type: 'text',
        text: { preview_url: false, body },
      }),
    },
  );

  if (res.ok) return { ok: true };

  const detail = await res.text().catch(() => '');
  return { ok: false, error: `${res.status} ${detail.slice(0, 300)}` };
}
