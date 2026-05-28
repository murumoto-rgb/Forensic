import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";

type Mode = "sign-in" | "sign-up";

export function LoginPage() {
  const [mode, setMode] = useState<Mode>("sign-in");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [needsConfirmation, setNeedsConfirmation] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    setNeedsConfirmation(false);
    try {
      if (mode === "sign-in") {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) setError(error.message);
      } else {
        const { data, error } = await supabase.auth.signUp({ email, password });
        if (error) {
          setError(error.message);
        } else if (data.user && !data.session) {
          // Email confirmation required (Supabase default).
          setNeedsConfirmation(true);
        }
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="flex h-full items-center justify-center">
      <div className="w-full max-w-sm rounded-lg border border-neutral-800 bg-neutral-900 p-8 shadow-2xl">
        <h1 className="mb-2 text-2xl font-semibold text-neutral-100">SitePhoto - Forensic</h1>
        <p className="mb-6 text-sm text-neutral-400">
          {mode === "sign-in" ? "Sign in to continue." : "Create your account."}
        </p>

        {needsConfirmation ? (
          <div className="rounded border border-emerald-700 bg-emerald-900/30 p-4 text-sm text-emerald-200">
            Check your inbox for a confirmation link. After confirming, come back here and sign in.
          </div>
        ) : (
          <form className="space-y-4" onSubmit={handleSubmit}>
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-400">Email</label>
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
                autoComplete="email"
                className="w-full rounded border border-neutral-700 bg-neutral-950 px-3 py-2 text-neutral-100 focus:border-accent focus:outline-none"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-400">Password</label>
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                minLength={8}
                autoComplete={mode === "sign-in" ? "current-password" : "new-password"}
                className="w-full rounded border border-neutral-700 bg-neutral-950 px-3 py-2 text-neutral-100 focus:border-accent focus:outline-none"
              />
            </div>
            {error && (
              <div className="rounded border border-red-800 bg-red-950/40 p-2 text-sm text-red-300">
                {error}
              </div>
            )}
            <button
              type="submit"
              disabled={submitting}
              className="w-full rounded bg-accent px-4 py-2 font-medium text-neutral-950 hover:bg-accent-dark disabled:cursor-not-allowed disabled:opacity-50"
            >
              {submitting ? "…" : mode === "sign-in" ? "Sign in" : "Create account"}
            </button>
          </form>
        )}

        <button
          type="button"
          onClick={() => {
            setMode(mode === "sign-in" ? "sign-up" : "sign-in");
            setError(null);
            setNeedsConfirmation(false);
          }}
          className="mt-6 w-full text-center text-xs text-neutral-500 hover:text-neutral-300"
        >
          {mode === "sign-in"
            ? "Don't have an account? Create one."
            : "Already have an account? Sign in."}
        </button>
      </div>
    </div>
  );
}
