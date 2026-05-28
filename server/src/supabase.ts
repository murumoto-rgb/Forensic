/**
 * Supabase server-side clients.
 *
 * `supabaseAdmin` uses the **secret** key (service role). It bypasses
 * Row Level Security and is the path the server uses for every
 * database read/write. RLS is still on in the database as
 * defense-in-depth, but the server is trusted to enforce per-user
 * authorization at the application layer (i.e. every query
 * `.eq("owner_id", userId)`).
 *
 * `verifyUserJWT` decodes and verifies a Supabase Auth JWT against
 * the publishable key. Returns the resolved user, or null if the JWT
 * is missing, malformed, expired, or revoked.
 */

import { createClient, type SupabaseClient, type User } from "@supabase/supabase-js";
import { env } from "./env.js";

export const supabaseAdmin: SupabaseClient = createClient(
  env.SUPABASE_URL,
  env.SUPABASE_SECRET_KEY,
  {
    auth: {
      // The admin client never holds a user session.
      autoRefreshToken: false,
      persistSession: false,
    },
  }
);

export async function verifyUserJWT(jwt: string): Promise<User | null> {
  // Use the admin client's `auth.getUser(jwt)` — it validates the
  // token against Supabase Auth and returns the user on success.
  // Invalid / expired tokens return a non-null `error`.
  const { data, error } = await supabaseAdmin.auth.getUser(jwt);
  if (error || !data?.user) return null;
  return data.user;
}
