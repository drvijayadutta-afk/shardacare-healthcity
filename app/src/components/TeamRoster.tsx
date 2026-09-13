import { humanise } from '@/lib/format';

export interface RosterPerson { id: string; full_name: string; roles: string[] }

/**
 * Roles in the order they matter to a manager glancing at this panel:
 * who runs things, then who does the work, in the order it flows
 * (brief -> content -> design -> release). Anything not listed here
 * (a role added later) still shows, just alphabetically after these.
 */
const ROLE_ORDER = [
  'ADMIN', 'WORKFLOW_MANAGER', 'COORDINATOR', 'APPROVER',
  'CONTENT_WRITER', 'DESIGNER', 'SOCIAL_MEDIA',
  'CREATOR', 'REQUESTOR', 'VENDOR',
];

/**
 * The team roster, grouped by role rather than a flat list — a person with
 * more than one role (several people here hold two) appears once per role
 * they hold, since "who can approve" and "who designs" are different
 * questions a manager asks separately.
 */
export function TeamRoster({ people }: { people: RosterPerson[] }) {
  const byRole = new Map<string, Set<string>>();
  for (const p of people) {
    const roles = p.roles.length ? p.roles : ['UNASSIGNED'];
    for (const r of roles) {
      if (!byRole.has(r)) byRole.set(r, new Set());
      byRole.get(r)!.add(p.full_name);
    }
  }

  const orderedRoles = [
    ...ROLE_ORDER.filter((r) => byRole.has(r)),
    ...[...byRole.keys()].filter((r) => !ROLE_ORDER.includes(r) && r !== 'UNASSIGNED').sort(),
    ...(byRole.has('UNASSIGNED') ? ['UNASSIGNED'] : []),
  ];

  return (
    <aside className="rounded-lg border border-slate-200 bg-white p-4 lg:sticky lg:top-6">
      <h2 className="text-sm font-semibold text-black">Team</h2>
      <p className="mt-0.5 text-xs text-black">{people.length} people, by role</p>
      <div className="mt-3 space-y-3">
        {orderedRoles.map((role) => (
          <div key={role}>
            <h3 className="text-xs font-semibold uppercase tracking-wide text-black">
              {role === 'UNASSIGNED' ? 'No role assigned' : humanise(role)}
            </h3>
            <ul className="mt-1 space-y-0.5">
              {[...byRole.get(role)!].sort().map((name) => (
                <li key={name} className="text-sm text-black">{name}</li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </aside>
  );
}
