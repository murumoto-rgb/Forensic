# server

Fastify + TypeScript API for the Forensic project. Hosts at
Render in production; runs locally via `pnpm dev` during
development.

## Setup (first time)

1. From the repo root: `pnpm install`.
2. `cp server/.env.local.example server/.env.local`.
3. Edit `server/.env.local` and fill in the Supabase values (URL,
   publishable key, secret key). The secret key is the sensitive
   one — never commit `.env.local`. The example file is committed;
   `.env.local` is gitignored.

## Running locally

From the repo root:

```
pnpm --filter @forensic/server dev
```

The server starts on `http://localhost:3000` by default (change
via `PORT` in `.env.local`). Hot reloads on file save via `tsx
watch`.

Smoke-test it:

```
curl http://localhost:3000/healthz
# → {"status":"ok","serverManifestSchemaVersion":1}
```

## Routes

| Method | Path                  | Description                       |
| ------ | --------------------- | --------------------------------- |
| GET    | `/healthz`            | Liveness probe + schema version.  |

(More routes land in subsequent commits.)

## Architecture

- `src/index.ts` — Fastify bootstrap; registers plugins + routes.
- `src/env.ts` — env-var loading + validation. Server refuses to
  start if anything is missing or malformed.
- `src/routes/` — one file per HTTP route, exposed as a Fastify
  plugin.

The server uses the Supabase **secret key** for all database
calls, which bypasses Row Level Security. Auth happens at the
HTTP boundary: every protected route requires a valid Supabase
JWT in the `Authorization: Bearer <jwt>` header; the middleware
decodes the JWT to identify the calling user and enforces access
at the application layer.
