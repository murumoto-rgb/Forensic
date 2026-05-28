# web

React + Vite SPA for the Forensic project. Hosted on Vercel.

## Setup (first time)

1. From the repo root: `pnpm install`.
2. `cp web/.env.local.example web/.env.local`.
3. Edit `web/.env.local` and fill in the three values:
   - `VITE_SUPABASE_URL` — Project URL from Supabase Settings → API
   - `VITE_SUPABASE_PUBLISHABLE_KEY` — the publishable key (safe in browser)
   - `VITE_API_URL` — `http://localhost:3000` for local dev; your
     Render URL in production

## Running locally

From the repo root:

```
pnpm --filter @forensic/web dev
```

Vite serves at `http://localhost:5173` by default. Hot reloads
on save.

Run the server alongside it (in another terminal):

```
pnpm --filter @forensic/server dev
```

## Pages

- `/` — login (email + password). Falls through to `/projects`
  once signed in.
- `/projects` — protected; lists the current user's projects
  from the server.

## Stack

- React 19 + React Router v7
- Vite 6
- Tailwind CSS v4 (via `@tailwindcss/vite`)
- Supabase Auth (`@supabase/supabase-js`) — publishable key only,
  never the secret.
- Calls the Forensic server's REST API via `src/lib/api.ts`.
