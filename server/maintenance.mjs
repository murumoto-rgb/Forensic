/**
 * Dependency-free release barrier for hosts without a maintenance feature.
 * This entrypoint never imports the application, database, storage or workers.
 * A healthy listener is NOT evidence that the application schema is ready.
 */
import { createServer } from "node:http";

const rawPort = process.env.PORT ?? "3000";
if (!/^\d+$/.test(rawPort) || Number(rawPort) > 65535) {
  throw new Error("PORT must be an integer between 0 and 65535.");
}
const gitSha = process.env.RENDER_GIT_COMMIT || null;
const health = JSON.stringify({
  status: "maintenance",
  gitSha,
  gitShaShort: gitSha?.slice(0, 8) ?? null,
});
const unavailable = JSON.stringify({
  error: "maintenance",
  message: "Service temporarily unavailable during an upgrade. Please retry later.",
});

const server = createServer({
  maxHeaderSize: 16 * 1024,
  requestTimeout: 15_000,
  headersTimeout: 15_000,
  keepAliveTimeout: 1_000,
}, (request, response) => {
  const readiness = (request.method === "GET" || request.method === "HEAD")
    && request.url?.split("?", 1)[0] === "/healthz";
  const body = readiness ? health : unavailable;
  response.writeHead(readiness ? 200 : 503, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "Connection": "close",
    ...(readiness ? {} : { "Retry-After": "60" }),
  });
  response.end(request.method === "HEAD" ? undefined : body);
});

server.listen(Number(rawPort), process.env.FORENSIC_MAINTENANCE_HOST ?? "0.0.0.0", () => {
  const address = server.address();
  console.log(JSON.stringify({
    event: "maintenance-listener-ready",
    port: typeof address === "object" && address !== null ? address.port : null,
    gitShaShort: gitSha?.slice(0, 8) ?? null,
  }));
});

function stop() {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5_000).unref();
}
process.once("SIGTERM", stop);
process.once("SIGINT", stop);
