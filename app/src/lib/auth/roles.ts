import { createClient } from '@/lib/supabase/server';
import { cache } from 'react';

export type RoleName =
  // The generic set from 0001
  | 'ADMIN' | 'WORKFLOW_MANAGER' | 'APPROVER'
  | 'CREATOR' | 'COORDINATOR' | 'REQUESTOR' | 'VENDOR'
  // The team's actual disciplines, added in 0011
  | 'CONTENT_WRITER' | 'DESIGNER' | 'SOCIAL_MEDIA' | 'MANAGER' | 'FINAL_APPROVER'
  // Who may move work between stages, added in 0015
  | 'STATUS_CONTROLLER';

export interface CurrentUser {
  id: string;
  email: string;
  fullName: string;
  roles: RoleName[];
  permissions: string[];
}

/**
 * The signed-in user with their roles resolved.
 *
 * These mirror the SQL helpers public.has_role() / has_permission() used by the
 * RLS policies. They decide what the UI *offers*; the database decides what is
 * actually allowed. Never treat a check here as the security boundary — hiding
 * a button is not the same as forbidding the action, and the policies are what
 * stop a hand-crafted request.
 *
 * cache() dedupes this across one render pass, so a layout and three components
 * asking for the current user cost a single round trip.
 */
export const getCurrentUser = cache(async (): Promise<CurrentUser | null> => {
  const supabase = await createClient();

  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) return null;

  const { data: profile } = await supabase
    .from('users')
    .select('id, email, full_name, user_roles(roles(name, permissions))')
    .eq('id', user.id)
    .single();

  if (!profile) {
    // Authenticated but no profile row. The handle_new_auth_user trigger
    // normally creates one; if it is missing, fall back to auth data rather
    // than showing a broken page.
    return {
      id: user.id,
      email: user.email ?? '',
      fullName: user.email?.split('@')[0] ?? 'Unknown',
      roles: [],
      permissions: [],
    };
  }

  type RoleRow = { roles: { name: string; permissions: string[] } | null };
  const roleRows = (profile.user_roles ?? []) as unknown as RoleRow[];

  const roles = roleRows.map((r) => r.roles?.name).filter(Boolean) as RoleName[];
  const permissions = [
    ...new Set(roleRows.flatMap((r) => r.roles?.permissions ?? [])),
  ];

  return {
    id: profile.id,
    email: profile.email,
    fullName: profile.full_name,
    roles,
    permissions,
  };
});

export function hasRole(user: CurrentUser | null, ...names: RoleName[]): boolean {
  if (!user) return false;
  return names.some((n) => user.roles.includes(n));
}

export function hasPermission(user: CurrentUser | null, permission: string): boolean {
  if (!user) return false;
  return user.permissions.includes(permission);
}

/** Can this user see the management view rather than just their own queue? */
export function canViewAllWork(user: CurrentUser | null): boolean {
  return hasRole(user, 'ADMIN', 'WORKFLOW_MANAGER', 'COORDINATOR');
}

/**
 * Can this user start new work? Deliberately narrower than canViewAllWork
 * (0020) — a workflow manager or coordinator still sees the Control Tower and
 * Board, reassigns, approves, but does not open new jobs. Matches
 * work_items_insert / jobs_insert exactly, so the button is never offered
 * where the database would refuse it.
 */
export function canCreateWork(user: CurrentUser | null): boolean {
  return hasRole(user, 'ADMIN');
}
