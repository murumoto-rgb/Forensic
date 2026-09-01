import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";

const entrypoint = fileURLToPath(new URL("../maintenance.mjs", import.meta.url));
const sha = "1234567890abcdef1234567890abcdef12345678";
let child: ChildProcess;
let origin: string;

beforeAll(async () => {
  // Do not pass Supabase, storage, auth, or any other application environment.
  // Booting and denying requests must work before feature migrations exist.
  child = spawn(process.execPath, [entrypoint], {
    env: { PORT: "0", FORENSIC_MAINTENANCE_HOST: "127.0.0.1", RENDER_GIT_COMMIT: sha },
    stdio: ["ignore", "pipe", "pipe"],
  });
  await new Promise<void>((resolve, reject) => {
    const deadline = setTimeout(() => reject(new Error("Maintenance listener did not start")), 5_000);
    let output = "";
    child.once("error", error => { clearTimeout(deadline); reject(error); });
    child.once("exit", code => { clearTimeout(deadline); reject(new Error(`Maintenance listener exited: ${code}`)); });
    child.stdout?.on("data", bytes => {
      output += String(bytes);
      if (!output.includes("\n")) return;
      try {
        const ready = JSON.parse(output.split("\n")[0] ?? "");
        if (ready.event !== "maintenance-listener-ready" || !Number.isInteger(ready.port)) return;
        origin = `http://127.0.0.1:${ready.port}`;
        clearTimeout(deadline);
        resolve();
      } catch (error) { clearTimeout(deadline); reject(error); }
    });
  });
});

afterAll(async () => {
  if (!child || child.exitCode !== null) return;
  await new Promise<void>(resolve => {
    const deadline = setTimeout(() => { child.kill("SIGKILL"); }, 3_000);
    child.once("exit", () => { clearTimeout(deadline); resolve(); });
    child.kill("SIGTERM");
  });
});

describe("standalone maintenance release barrier", () => {
  it("boots without application credentials and reports maintenance, not database readiness", async () => {
    const response = await fetch(`${origin}/healthz?release-probe=1`);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ status: "maintenance", gitSha: sha, gitShaShort: sha.slice(0, 8) });
  });

  it("refuses every application method even when the caller supplies credentials", async () => {
    for (const method of ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]) {
      const response = await fetch(`${origin}/v1/projects/33333333-3333-4333-8333-333333333333`, {
        method,
        headers: { authorization: "Bearer synthetic-test", "content-type": "application/json" },
        ...(["POST", "PUT", "PATCH"].includes(method) ? { body: '{"project":{"name":"must not save"}}' } : {}),
      });
      expect(response.status, method).toBe(503);
      expect(response.headers.get("retry-after"), method).toBe("60");
      expect(response.headers.get("cache-control"), method).toBe("no-store");
      if (method === "HEAD") expect(await response.text()).toBe("");
      else expect(await response.json()).toMatchObject({ error: "maintenance" });
    }
  });

  it("limits successful readiness to GET or HEAD on the exact health path", async () => {
    const head = await fetch(`${origin}/healthz`, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
    for (const path of ["/", "/healthz/", "/v1/files/upload-url"]) {
      const response = await fetch(origin + path);
      expect(response.status, path).toBe(503);
      await response.text();
    }
    const post = await fetch(`${origin}/healthz`, { method: "POST" });
    expect(post.status).toBe(503);
    await post.text();
  });
});
