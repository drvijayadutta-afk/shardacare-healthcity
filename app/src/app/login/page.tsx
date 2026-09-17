'use client';

import { useState, Suspense } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { Logo } from '@/components/Logo';

function SignInForm({ onForgotPassword }: { onForgotPassword: () => void }) {
  const router = useRouter();
  const params = useSearchParams();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const linkError = params.get('error') === 'reset-link-invalid';

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.auth.signInWithPassword({ email, password });

    if (error) {
      setError(error.message);
      setBusy(false);
      return;
    }
    // Back to wherever middleware intercepted them, else their queue.
    router.push(params.get('next') || '/my-work');
    router.refresh();
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div>
        <label htmlFor="email" className="block text-sm font-medium text-black">
          Email
        </label>
        <input
          id="email" type="email" required autoComplete="email"
          value={email} onChange={(e) => setEmail(e.target.value)}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                     focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
        />
      </div>
      <div>
        <div className="flex items-center justify-between">
          <label htmlFor="password" className="block text-sm font-medium text-black">
            Password
          </label>
          <button
            type="button"
            onClick={onForgotPassword}
            className="text-xs font-medium text-brand-navy hover:underline"
          >
            Forgot password?
          </button>
        </div>
        <input
          id="password" type="password" required autoComplete="current-password"
          value={password} onChange={(e) => setPassword(e.target.value)}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                     focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
        />
      </div>

      {linkError && !error && (
        <p role="alert" className="rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-800">
          That reset link has expired or was already used. Request a new one above.
        </p>
      )}
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
        {busy ? 'Signing in…' : 'Sign in'}
      </button>
    </form>
  );
}

function ForgotPasswordForm({ onBack }: { onBack: () => void }) {
  const [email, setEmail] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/callback?next=/auth/reset-password`,
    });
    setBusy(false);

    // Supabase does not reveal whether the address has an account either way
    // — showing the same confirmation regardless keeps this app from doing
    // so itself. A real send failure (bad request, rate limit) still shows.
    if (error) {
      setError(error.message);
      return;
    }
    setSent(true);
  }

  if (sent) {
    return (
      <div className="space-y-4">
        <p className="text-sm text-black">
          If an account exists for <span className="font-medium">{email}</span>, a reset
          link has been sent. Open it to choose a new password.
        </p>
        <button
          type="button"
          onClick={onBack}
          className="text-sm font-medium text-brand-navy hover:underline"
        >
          Back to sign in
        </button>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <p className="text-sm text-black">
        Enter the email your account was created with — we&apos;ll send a link to set a
        new password.
      </p>
      <div>
        <label htmlFor="reset-email" className="block text-sm font-medium text-black">
          Email
        </label>
        <input
          id="reset-email" type="email" required autoComplete="email"
          value={email} onChange={(e) => setEmail(e.target.value)}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                     focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
        />
      </div>

      {error && (
        <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}

      <div className="flex items-center gap-4">
        <button
          type="submit" disabled={busy}
          className="rounded-md bg-brand-navy px-4 py-2 text-sm font-medium text-white
                     hover:bg-brand-navy-dark disabled:opacity-50"
        >
          {busy ? 'Sending…' : 'Send reset link'}
        </button>
        <button type="button" onClick={onBack} className="text-sm font-medium text-black hover:underline">
          Back to sign in
        </button>
      </div>
    </form>
  );
}

function LoginFlow() {
  const [mode, setMode] = useState<'signin' | 'forgot'>('signin');

  return mode === 'signin'
    ? <SignInForm onForgotPassword={() => setMode('forgot')} />
    : <ForgotPasswordForm onBack={() => setMode('signin')} />;
}

export default function LoginPage() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-50 px-4">
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-8 shadow-sm">
        <Logo className="mb-4" />
        <h1 className="text-lg font-semibold text-black">Control Tower</h1>
        <p className="mt-1 mb-6 text-sm text-black">Sign in to see your work.</p>
        <Suspense fallback={<p className="text-sm text-black">Loading…</p>}>
          <LoginFlow />
        </Suspense>
      </div>
    </main>
  );
}
