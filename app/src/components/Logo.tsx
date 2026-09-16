/**
 * The ShardaCare HealthCity wordmark.
 *
 * The real logo (lotus/swan mark, gradient wordmark, "HEALTHCITY" badge)
 * arrived as an image pasted into chat, not as an uploaded file — there is
 * nothing on disk to reference. This renders a styled text stand-in using the
 * brand navy from globals.css so the header and login page are on-brand today.
 *
 * To switch to the real mark: save it to app/public/shardacare-logo.png (and
 * a square crop for the favicon), then replace the JSX below with
 * `<img src="/shardacare-logo.png" alt="ShardaCare HealthCity" className="h-8" />`.
 * Nothing else needs to change — every call site just renders <Logo />.
 */
export function Logo({ className = '' }: { className?: string }) {
  return (
    <span className={`inline-flex items-baseline gap-1.5 ${className}`}>
      <span className="text-lg font-semibold tracking-tight text-brand-navy">
        ShardaCare
      </span>
      <span className="rounded bg-brand-navy px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider text-white">
        HealthCity
      </span>
    </span>
  );
}
