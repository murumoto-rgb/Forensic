/**
 * JWT-based auth middleware.
 *
 * Registered as a `preHandler` hook on any route plugin that needs
 * authentication. Reads `Authorization: Bearer <jwt>` from the
 * request, verifies the JWT against Supabase Auth, and attaches the
 * resolved user to `request.user`. On any failure (missing header,
 * malformed token, expired/revoked) the request is short-circuited
 * with `401 Unauthorized` and the handler never runs.
 */

import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from "fastify";
import fp from "fastify-plugin";
import { verifyUserJWT } from "../supabase.js";
import { setRequestUser } from "../sentry.js";
import { isOrgAdmin } from "../access.js";

const BEARER_RE = /^Bearer\s+(.+)$/;

export async function requireAuth(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const header = request.headers["authorization"];
  if (typeof header !== "string") {
    reply.code(401).send({ error: "unauthorized", message: "Missing Authorization header" });
    return;
  }
  const match = BEARER_RE.exec(header);
  if (!match || !match[1]) {
    reply.code(401).send({
      error: "unauthorized",
      message: "Authorization header must be 'Bearer <jwt>'",
    });
    return;
  }
  const jwt = match[1].trim();
  const user = await verifyUserJWT(jwt);
  if (!user || !user.email) {
    reply.code(401).send({ error: "unauthorized", message: "Invalid or expired token" });
    return;
  }
  request.user = { id: user.id, email: user.email };
  // Tag the current request scope with the user id so any later
  // exception captured by `setErrorHandler` carries enough context
  // to triage without us threading the user through every callsite.
  setRequestUser(user.id);
}

/**
 * Fastify plugin that registers `requireAuth` as a preHandler. Any
 * route registered after `await app.register(authPlugin)` will
 * reject requests without a valid Supabase JWT before the handler
 * runs.
 *
 * `request.user` is typed as always present (see types.ts); the
 * type augmentation is honored by the runtime because every
 * protected route lives inside a plugin that's registered the
 * auth middleware first.
 */
export const authPlugin: FastifyPluginAsync = fp(async (app) => {
  app.addHook("preHandler", requireAuth);
});

/**
 * preHandler that 403s any caller without `profiles.is_admin = true`.
 * Use as a second-stage gate after `authPlugin` for `/v1/admin/*`
 * routes. Phase 3, Build #5.123.1.
 */
export async function requireAdmin(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  if (!(await isOrgAdmin(request.user.id))) {
    reply.code(403).send({
      error: "forbidden",
      message: "Admin role required.",
    });
  }
}
