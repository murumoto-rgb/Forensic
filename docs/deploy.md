# Deploy notes

The Forensic stack runs on three external services:

- **Supabase** — Postgres + Auth. Project is `forensic` in the
  Baykal Consulting organization. Migrations live in
  `supabase/migrations/` and are applied manually via
  Dashboard → SQL Editor (see `supabase/README.md`).
- **Render** — hosts the Fastify server. Config lives in
  `render.yaml` at the repo root; deploys from `main`.
- **Vercel** — hosts the React + Vite SPA. Config lives in
  `vercel.json` at the repo root; deploys from `main`.

Both Render and Vercel auto-deploy on every push to `main`. Feature
branches don't auto-deploy unless you explicitly enable preview
deploys per service.

## First-time setup order

There's a chicken-and-egg between Render and Vercel via CORS — the
server needs to know the Vercel URL to whitelist it, and the web
app needs to know the Render URL to call it. Order:

1. **Render first.** Deploy the server. Note its public URL
   (e.g. `https://forensic-server.onrender.com`).
2. **Vercel second.** Deploy the web app, setting
   `VITE_API_URL` to the Render URL above. Note Vercel's URL
   (e.g. `https://forensic-xxx.vercel.app`).
3. **Render env vars: update `CORS_ORIGINS`.** Go back to Render
   → forensic-server → Environment → edit `CORS_ORIGINS` to the
   Vercel URL. Render redeploys automatically (~1 minute).

After step 3, the web app can talk to the server.

## Environment variables

### Render (`forensic-server`)

| Key                          | Where it comes from                                |
| ---------------------------- | -------------------------------------------------- |
| `NODE_ENV`                   | Auto-set to `production` in `render.yaml`.        |
| `SUPABASE_URL`               | Supabase Dashboard → Settings → API → Project URL. |
| `SUPABASE_PUBLISHABLE_KEY`   | Supabase Dashboard → Settings → API.               |
| `SUPABASE_SECRET_KEY`        | Supabase Dashboard → Settings → API.               |
| `CORS_ORIGINS`               | Vercel URL once Vercel is deployed.                |
| `PORT`                       | Render auto-sets this.                             |

### Vercel (`forensic-web`)

| Key                              | Where it comes from                                |
| -------------------------------- | -------------------------------------------------- |
| `VITE_SUPABASE_URL`              | Supabase Dashboard → Settings → API → Project URL. |
| `VITE_SUPABASE_PUBLISHABLE_KEY`  | Supabase Dashboard → Settings → API.               |
| `VITE_API_URL`                   | Render URL.                                        |

The Supabase **secret** key never goes into Vercel — secrets stay
on the server side only.
