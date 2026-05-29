import { createClient } from "@supabase/supabase-js";
import { env } from "./env";

export const supabase = createClient(
  env.SUPABASE_URL,
  env.SUPABASE_PUBLISHABLE_KEY,
  {
    auth: {
      // Persist sessions in localStorage and auto-refresh in the
      // background; standard SPA behaviour.
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  }
);

/**
 * Sign out **this browser only**. `{ scope: 'local' }` is deliberate:
 * Supabase's default (`'global'`) revokes every session for the user
 * across all devices, which meant signing out on the web also kicked
 * the iPhone. We want device-local sign-out. Every sign-out path
 * (the buttons + the 401 handler in api.ts) routes through here so
 * the scope choice lives in exactly one place.
 */
export function signOutLocal() {
  return supabase.auth.signOut({ scope: "local" });
}
