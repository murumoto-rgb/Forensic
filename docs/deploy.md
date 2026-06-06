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
| `R2_ACCOUNT_ID`              | Cloudflare R2 dashboard.                            |
| `R2_ACCESS_KEY_ID`           | R2 API token (Object Read & Write).                 |
| `R2_SECRET_ACCESS_KEY`       | R2 API token.                                       |
| `R2_BUCKET`                  | R2 bucket name (`forensic-photos`).                 |
| `ANTHROPIC_API_KEY`          | console.anthropic.com → API Keys. Optional.         |
| `SENTRY_DSN`                 | sentry.io → server project → Client Keys. Optional. |
| `SENTRY_RELEASE`             | Optional — defaults to `RENDER_GIT_COMMIT`.         |
| `SENTRY_TRACES_SAMPLE_RATE`  | Optional — default 0.1.                             |
| `RESEND_API_KEY`             | resend.com → API Keys. Optional — emails no-op when blank. |
| `RESEND_FROM_EMAIL`          | A verified sender on Resend (or `onboarding@resend.dev` in sandbox). Optional. |
| `WEB_BASE_URL`               | Vercel URL of the web app (used in email "open project" links). Optional but required for emails to fire. |

### Vercel (`forensic-web`)

| Key                              | Where it comes from                                |
| -------------------------------- | -------------------------------------------------- |
| `VITE_SUPABASE_URL`              | Supabase Dashboard → Settings → API → Project URL. |
| `VITE_SUPABASE_PUBLISHABLE_KEY`  | Supabase Dashboard → Settings → API.               |
| `VITE_API_URL`                   | Render URL.                                        |
| `VITE_SENTRY_DSN`                | sentry.io → web project → Client Keys. Optional.   |
| `VITE_SENTRY_TRACES_SAMPLE_RATE` | Optional — default 0.1.                            |
| `VITE_POSTHOG_KEY`               | posthog.com → Project Settings → API Key. Optional.|
| `VITE_POSTHOG_HOST`              | Optional — defaults to `https://us.i.posthog.com`. |

The Supabase **secret** key never goes into Vercel — secrets stay
on the server side only. Sentry / PostHog are optional: omit their
vars and the SDKs no-op (Build #5.57.1). Resend is also optional:
without `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, and `WEB_BASE_URL`,
the lock-collaboration notifications (Build #5.61.1) no-op silently.

## Related docs

- **`docs/ops-runbook.md`** — day-2 operations: what's running where,
  how to read logs, the common-incident playbook ("server is down",
  "photos won't load", "AI tagging 503s", etc.).
- **`docs/backup-restore-drill.md`** — what's backed up, where, and
  the step-by-step recovery procedure for each failure class
  (dropped DB row, corrupted manifest, lost R2 object, full
  project-level restore).
