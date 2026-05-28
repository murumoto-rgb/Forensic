/**
 * Fastify module augmentation — adds typed `request.user` so route
 * handlers under the auth middleware can read the caller's identity
 * without `as any` casts.
 */

import "fastify";

declare module "fastify" {
  interface FastifyRequest {
    user: {
      id: string;
      email: string;
    };
  }
}
