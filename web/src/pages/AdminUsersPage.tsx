import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { AdminUser } from "@forensic/shared";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError } from "../lib/api";

/**
 * Admin Users page (Build #5.125.1).
 *
 * Lists every user with their org-admin flag + per-project
 * assignments + a "pending" badge (invited but never signed in).
 * Admins can: invite by email; toggle org admin; remove a user
 * (with confirm). Per-project assignment is on the project Info
 * tab, not here — this page keeps the read-only summary so an
 * admin can audit who has access to what.
 *
 * Role gating: the server 403s non-admins on every `/v1/admin/*`
 * route. We also call `api.getMe()` on mount and render a
 * not-authorized panel rather than letting the page show empty.
 */
interface Props {
  session: Session;
}

interface LoadState {
  users: AdminUser[];
  meIsAdmin: boolean;
}

export function AdminUsersPage({ session }: Props) {
  const [load, setLoad] = useState<LoadState | "loading" | { error: string }>(
    "loading"
  );
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviting, setInviting] = useState(false);
  const [inviteSuccess, setInviteSuccess] = useState<string | null>(null);
  const [inviteError, setInviteError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoad("loading");
    try {
      const me = await api.getMe();
      if (!me.isAdmin) {
        setLoad({ users: [], meIsAdmin: false });
        return;
      }
      const list = await api.listAdminUsers();
      setLoad({ users: list.users, meIsAdmin: true });
    } catch (e: unknown) {
      const message =
        e instanceof ApiError
          ? `${e.status} ${e.errorCode}: ${e.message}`
          : "Failed to load users";
      setLoad({ error: message });
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  async function invite() {
    const email = inviteEmail.trim();
    if (!email) return;
    setInviting(true);
    setInviteError(null);
    setInviteSuccess(null);
    try {
      await api.inviteUser(email);
      setInviteSuccess(`Invite sent to ${email}.`);
      setInviteEmail("");
      await reload();
    } catch (e: unknown) {
      setInviteError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Invite failed"
      );
    } finally {
      setInviting(false);
    }
  }

  return (
    <div className="mx-auto max-w-4xl px-6 py-10">
      <header className="mb-6 flex items-start justify-between gap-4">
        <div>
          <Link
            to="/settings"
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← Settings
          </Link>
          <h1 className="text-2xl font-semibold">Team & access</h1>
          <p className="mt-1 text-xs text-neutral-500">
            Invite users, manage org admins, and audit per-project
            access. Per-project assignment lives on each project's
            Info tab.
          </p>
        </div>
        <div className="flex items-center gap-2 text-right">
          <span className="text-xs text-neutral-500">{session.user.email}</span>
          <button
            type="button"
            onClick={() => signOutLocal()}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Sign out
          </button>
        </div>
      </header>

      {load === "loading" && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {load !== "loading" && "error" in load && (
        <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {load.error}
        </div>
      )}

      {load !== "loading" && "meIsAdmin" in load && !load.meIsAdmin && (
        <div className="rounded border border-neutral-800 bg-neutral-950/40 p-6 text-sm text-neutral-300">
          You don't have admin access. Ask an existing admin to grant
          you the role.
          <div className="mt-3">
            <Link
              to="/projects"
              className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800"
            >
              ← Back to projects
            </Link>
          </div>
        </div>
      )}

      {load !== "loading" && "users" in load && load.meIsAdmin && (
        <>
          <section className="mb-6 rounded border border-neutral-800 bg-neutral-950/40 p-5">
            <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-neutral-400">
              Invite by email
            </h2>
            <div className="flex flex-wrap items-center gap-2">
              <input
                type="email"
                value={inviteEmail}
                onChange={(e) => setInviteEmail(e.target.value)}
                placeholder="user@company.com"
                className="min-w-[16rem] flex-1 rounded border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-neutral-100 placeholder:text-neutral-500"
                disabled={inviting}
              />
              <button
                type="button"
                onClick={() => void invite()}
                disabled={inviting || !inviteEmail.trim()}
                className="rounded border border-blue-500 bg-blue-600/80 px-4 py-2 text-sm font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {inviting ? "Sending…" : "Send invite"}
              </button>
            </div>
            {inviteError && (
              <div className="mt-2 text-xs text-red-300">{inviteError}</div>
            )}
            {inviteSuccess && (
              <div className="mt-2 text-xs text-emerald-300">{inviteSuccess}</div>
            )}
            <p className="mt-3 text-xs text-neutral-500">
              Supabase emails them a magic link. They set their
              password on first sign-in.
            </p>
          </section>

          <section className="rounded border border-neutral-800 bg-neutral-950/40">
            <div className="border-b border-neutral-800 px-5 py-3 text-sm font-semibold uppercase tracking-wide text-neutral-400">
              Users · {load.users.length}
            </div>
            <ul className="divide-y divide-neutral-800">
              {load.users.map((u) => (
                <UserRow
                  key={u.id}
                  user={u}
                  currentUserId={session.user.id}
                  onChanged={() => void reload()}
                />
              ))}
            </ul>
          </section>
        </>
      )}
    </div>
  );
}

interface UserRowProps {
  user: AdminUser;
  currentUserId: string;
  onChanged: () => void;
}

function UserRow({ user, currentUserId, onChanged }: UserRowProps) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmRemove, setConfirmRemove] = useState(false);
  const isSelf = user.id === currentUserId;

  async function toggleAdmin() {
    setBusy(true);
    setError(null);
    try {
      await api.setUserAdmin(user.id, !user.isAdmin);
      onChanged();
    } catch (e: unknown) {
      setError(
        e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Update failed"
      );
      setBusy(false);
    }
  }

  async function remove() {
    setBusy(true);
    setError(null);
    try {
      await api.removeUser(user.id);
      onChanged();
    } catch (e: unknown) {
      setError(
        e instanceof ApiError ? `${e.errorCode}: ${e.message}` : "Remove failed"
      );
      setBusy(false);
      setConfirmRemove(false);
    }
  }

  return (
    <>
      <li className="flex flex-wrap items-start justify-between gap-3 px-5 py-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="truncate text-sm text-neutral-100">{user.email}</span>
            {user.isAdmin && (
              <span className="rounded bg-blue-900/60 px-1.5 text-[10px] font-medium text-blue-200">
                Admin
              </span>
            )}
            {user.pending && (
              <span className="rounded bg-amber-900/60 px-1.5 text-[10px] font-medium text-amber-200">
                Invited (pending)
              </span>
            )}
            {isSelf && (
              <span className="rounded bg-neutral-800 px-1.5 text-[10px] font-medium text-neutral-300">
                You
              </span>
            )}
          </div>
          {user.displayName && (
            <div className="text-xs text-neutral-500">{user.displayName}</div>
          )}
          <div className="mt-1 text-xs text-neutral-500">
            {user.assignments.length === 0 ? (
              user.isAdmin ? (
                "Admin — access to every project"
              ) : (
                "No project assignments"
              )
            ) : (
              <>
                Assigned to{" "}
                {user.assignments.map((a, i) => (
                  <span key={a.projectId}>
                    {i > 0 && ", "}
                    <span className="text-neutral-300">{a.projectName}</span>
                    <span className="text-neutral-500"> ({a.role})</span>
                  </span>
                ))}
              </>
            )}
          </div>
          {error && (
            <div className="mt-1 text-xs text-red-400">{error}</div>
          )}
        </div>
        <div className="flex flex-shrink-0 items-center gap-2">
          <button
            type="button"
            onClick={() => void toggleAdmin()}
            disabled={busy}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800 disabled:opacity-50"
            title={user.isAdmin ? "Demote to non-admin" : "Make this user an org admin"}
          >
            {busy ? "…" : user.isAdmin ? "Demote admin" : "Make admin"}
          </button>
          <button
            type="button"
            onClick={() => setConfirmRemove(true)}
            disabled={busy || isSelf}
            className="rounded border border-red-800 px-3 py-1 text-xs text-red-300 hover:bg-red-950/40 disabled:cursor-not-allowed disabled:opacity-50"
            title={
              isSelf
                ? "You can't delete your own account."
                : "Revoke all memberships and delete this user."
            }
          >
            Remove
          </button>
        </div>
      </li>

      {confirmRemove && (
        <li
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-100">
              Remove <span className="font-semibold">{user.email}</span>?
            </div>
            <div className="text-xs text-neutral-400">
              Revokes all project memberships and deletes the user.
              If they own projects, the server will refuse — reassign
              ownership first.
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmRemove(false)}
                disabled={busy}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => void remove()}
                disabled={busy}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60 disabled:opacity-50"
              >
                {busy ? "Removing…" : "Remove"}
              </button>
            </div>
          </div>
        </li>
      )}
    </>
  );
}
