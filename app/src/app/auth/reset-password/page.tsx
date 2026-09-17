'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { Logo } from '@/components/Logo';

/** Reached only from /auth/callback, which exchanges the emailed link's code
 * for a session before redirecting here. If that never happened — a stale
 * bookmark, a link opened twice — there is no session to set a password on,
 * so this checks rather than assuming one exists. */
function useHasRecoverySession() {
  const [state, setState] = useState<'checking' | 'present' | 'missing'>('checking');

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getUser().then(({ data: { user } }) => {
      setState(user ? 'present' : 'missing');
    });
  }, []);

  return state;
}

function ResetPasswordForm() {
  const router = useRouter();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }
    if (password !== confirm) {
      setError('Passwords do not match.');
      return;
    }

    setBusy(true);
    const supabase = createClient();
    const { error } = await supabase.auth.updateUser({ password });
    setBusy(false);

    if (error) {
      setError(error.message);
      return;
    }
    setDone(true);
    setTimeout(() => {
      router.push('/my-work');
      router.refresh();
    }, 1500);
  }

  if (done) {
    return <p className="text-sm text-black">Password updated. Taking you to your work…</p>;
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div>
        <label htmlFor="new-password" className="block text-sm font-medium text-black">
          New password
        </label>
        <input
          id="new-password" type="password" required autoComplete="new-password"
          value={password} onChange={(e) => setPassword(e.target.value)}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                     focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
        />
      </div>
      <div>
        <label htmlFor="confirm-password" className="block text-sm font-medium text-black">
          Confirm password
        </label>
        <input
          id="confirm-password" type="password" required autoComplete="new-password"
          value={confirm} onChange={(e) => setConfirm(e.target.value)}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                     focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
        />
      </div>

      {error && (
        <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}

      <button
        type="submit" disabled={busy}
        className="w-full rounded-md bg-brand-navy px-4 py-2 text-sm font-medium text-white
                   hover:bg-brand-navy-dark disabled:opacity-50"
      >
        {busy ? 'Updating…' : 'Set new password'}
      </button>
    </form>
  );
}

function ResetPasswordBody() {
  const recovery = useHasRecoverySession();

  if (recovery === 'checking') {
    return <p className="text-sm text-black">Checking your reset link…</p>;
  }

  if (recovery === 'missing') {
    return (
      <div className="space-y-3">
        <p className="text-sm text-black">
          This reset link is no longer valid — it may have expired or already been used.
        </p>
        <a href="/login" className="text-sm font-medium text-brand-navy hover:underline">
          Back to sign in
        </a>
      </div>
    );
  }

  return <ResetPasswordForm />;
}

export default function ResetPasswordPage() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-50 px-4">
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-8 shadow-sm">
        <Logo className="mb-4" />
        <h1 className="text-lg font-semibold text-black">Set a new password</h1>
        <p className="mt-1 mb-6 text-sm text-black">Choose a new password for your account.</p>
        <ResetPasswordBody />
      </div>
    </main>
  );
}
