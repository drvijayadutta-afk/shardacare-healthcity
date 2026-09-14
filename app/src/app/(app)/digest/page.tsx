import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { formatForWhatsApp, type Digest, type DigestItem } from '@/lib/digest';
import { CopyDigest } from '@/components/CopyDigest';

export const dynamic = 'force-dynamic';

/**
 * Today's end-of-day status, in the exact words the 6pm message uses.
 *
 * This exists because the official WhatsApp API cannot post to a group (see
 * src/lib/digest.ts). Rather than pretend otherwise, the app produces the
 * message and one person taps Copy and pastes it into the group — which takes
 * about four seconds and needs no credentials, no vendor and no approval.
 *
 * The same text is what the cron sends to people individually once WhatsApp
 * credentials exist, so the group never drifts out of step with the app.
 *
 * daily_digest_rows() is SECURITY DEFINER, so this shows the whole team's work
 * to anyone signed in. That is deliberate and matches the request: the digest
 * is a group message — everybody is meant to see all of it.
 */

const BUCKET_LABEL: Record<string, string> = {
  overdue: 'Overdue',
  due_today: 'Due today',
  blocked: 'Blocked or on hold',
  in_flight: 'Moved today',
  completed_today: 'Completed today',
};

const BUCKET_TONE: Record<string, string> = {
  overdue: 'border-red-200 bg-red-50 text-red-900',
  due_today: 'border-amber-200 bg-amber-50 text-amber-900',
  blocked: 'border-slate-300 bg-slate-100 text-slate-800',
  in_flight: 'border-blue-200 bg-blue-50 text-blue-900',
  completed_today: 'border-emerald-200 bg-emerald-50 text-emerald-900',
};

const ORDER = ['overdue', 'due_today', 'blocked', 'in_flight', 'completed_today'];

export default async function DigestPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('daily_digest_rows');
  const items = (data ?? []) as DigestItem[];

  const today = new Date().toISOString().slice(0, 10);
  const totals = items.reduce<Record<string, number>>((acc, i) => {
    acc[i.bucket] = (acc[i.bucket] ?? 0) + 1;
    return acc;
  }, {});

  const digest: Digest = {
    generated_at: new Date().toISOString(),
    date: today,
    totals,
    items,
    recipients: [],
  };

  const text = formatForWhatsApp(
    digest,
    'https://shardacare-healthcity.vercel.app/work?filter=active',
  );

  return (
    <div className="space-y-5">
      <div>
        <Link href="/control-tower" className="text-sm text-black hover:text-black">
          ← Control Tower
        </Link>
        <h1 className="mt-2 text-xl font-semibold text-black">End of day</h1>
        <p className="mt-1 text-sm text-black">
          {new Date().toLocaleDateString('en-GB', {
            weekday: 'long', day: 'numeric', month: 'long',
          })}
          {' · '}
          {items.length} {items.length === 1 ? 'item' : 'items'}
        </p>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700">
          {error.message}
        </div>
      )}

      <section className="rounded-lg border border-slate-200 bg-white p-5">
        <h2 className="text-sm font-semibold text-black">Message for the group</h2>
        <p className="mt-1 text-sm text-black">
          Sent automatically at 6pm to everyone with a number on file. WhatsApp
          does not allow apps to post into a group, so copy this in.
        </p>
        <CopyDigest text={text} />
      </section>

      {ORDER.filter((b) => items.some((i) => i.bucket === b)).map((bucket) => {
        const rows = items.filter((i) => i.bucket === bucket);
        return (
          <section key={bucket} className="rounded-lg border border-slate-200 bg-white p-5">
            <h2 className="flex items-center gap-2 text-sm font-semibold text-black">
              {BUCKET_LABEL[bucket]}
              <span className={`rounded-full border px-2 py-0.5 text-xs font-medium ${BUCKET_TONE[bucket]}`}>
                {rows.length}
              </span>
            </h2>
            <ul className="mt-3 divide-y divide-slate-100">
              {rows.map((i) => (
                <li key={i.work_item_id} className="flex flex-wrap items-baseline gap-x-2 py-2 text-sm">
                  <Link
                    href={`/work/${i.work_item_id}`}
                    className="font-medium text-black hover:underline"
                  >
                    {i.name}
                  </Link>
                  <span className="text-black">
                    {i.stage_name.replace(/_/g, ' ').toLowerCase()}
                  </span>
                  <span className="ml-auto text-xs text-black">
                    {i.owner_name ?? 'unassigned'}
                  </span>
                </li>
              ))}
            </ul>
          </section>
        );
      })}

      {!items.length && !error && (
        <div className="rounded-lg border border-slate-200 bg-white p-10 text-center text-sm text-black">
          Nothing outstanding today.
        </div>
      )}
    </div>
  );
}
