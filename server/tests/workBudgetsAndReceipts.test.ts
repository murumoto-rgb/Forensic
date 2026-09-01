import { beforeAll, afterAll, beforeEach, afterEach, describe, expect, it } from "vitest";
import { readFile, readdir } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { ProjectSchema } from "@forensic/shared";

const owner = "11111111-1111-4111-8111-111111111111";
const editor = "22222222-2222-4222-8222-222222222222";
const viewer = "55555555-5555-4555-8555-555555555555";
const outsider = "66666666-6666-4666-8666-666666666666";
const pid = "33333333-3333-4333-8333-333333333333";
const entity = "44444444-4444-4444-8444-444444444444";
const objectKey = (n: number) => `${pid}/${entity}/photo/77777777-7777-4777-8777-${String(n).padStart(12, "0")}`;
const project = ProjectSchema.parse({ id: pid, name: "Synthetic budget test", createdAt: "2026-08-30T00:00:00Z", stopped: false, photos: [], trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 4 });
let db: PGlite;
async function rpc(name: string, args: unknown[]): Promise<any> {
  const result = await db.query(`select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as result`, args.map(value => value !== null && typeof value === "object" ? JSON.stringify(value) : value));
  return result.rows[0]?.result;
}
async function rejectsStatement(action: () => Promise<unknown>, message: RegExp) {
  await db.exec("savepoint expected_failure");
  await expect(action()).rejects.toThrow(message);
  await db.exec("rollback to expected_failure;release savepoint expected_failure");
}
async function calls(actor: string, kind: string) {
  return (await db.query("select calls from owner_work_budgets where user_id=$1 and kind=$2 and day=(now() at time zone 'UTC')::date", [actor, kind])).rows[0]?.calls ?? 0;
}
async function enqueue(table: "pdf_export_jobs" | "project_exports", actor: string, status = "queued") {
  const query = table === "pdf_export_jobs"
    ? "insert into pdf_export_jobs(project_id,requested_by,status) values($1,$2,$3) returning id"
    : "insert into project_exports(project_id,created_by,status,kind) values($1,$2,$3,'folder') returning id";
  return (await db.query(query, [pid, actor, status])).rows[0]!.id as string;
}
const receiptArgs = (n: number, actor = owner) => [pid, actor, entity, "photo", "evidence.jpg", objectKey(n), 100, "declared-hash"];
const issue = (n: number, actor = owner) => rpc("issue_upload_receipt", [...receiptArgs(n, actor), 900, null]);
const commit = (n: number, actor = owner) => rpc("commit_upload_receipt", [...receiptArgs(n, actor), null]);
const save = (expected: string, revision: string, frozen: boolean) => rpc("cas_project", [pid, owner, expected, revision, { ...project, isFrozen: frozen }, null]);

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
    create schema auth;create table auth.users(id uuid primary key,email text);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema public,auth to authenticated,service_role;`);
  const migrations = (await readdir(new URL("../../supabase/migrations/", import.meta.url))).filter(name => /^\d{4}.*\.sql$/.test(name)).sort();
  expect(migrations.some(name => name.startsWith("0019"))).toBe(true);
  for (const name of migrations) await db.exec(await readFile(new URL(`../../supabase/migrations/${name}`, import.meta.url), "utf8"));
  for (const actor of [owner, editor, viewer, outsider]) await db.query("insert into auth.users values($1,$2)", [actor, `${actor}@example.invalid`]);
}, 30000);
afterAll(async () => { await db?.close(); });
beforeEach(async () => {
  await db.exec("begin");
  await rpc("cas_project", [pid, owner, null, "r1", project, null]);
  await db.query("insert into project_members(project_id,user_id,role) values($1,$2,'editor'),($1,$3,'viewer')", [pid, editor, viewer]);
});
afterEach(async () => { await db.exec("rollback"); });

describe("durable AI budgets and leases, actual PostgreSQL functions", () => {
  it("enforces concurrency, actor-scoped release, and non-refundable daily charges", async () => {
    const first = await rpc("reserve_ai_work", [owner, 2, 1]);
    expect(first).toMatchObject({ ok: true, remaining: 1 });
    expect(await rpc("reserve_ai_work", [owner, 2, 1])).toMatchObject({ ok: false, reason: "concurrency", remaining: 1 });
    expect(await calls(owner, "ai")).toBe(1);
    await rpc("release_ai_work", [editor, first.lease]);
    expect((await db.query("select * from ai_work_leases")).rows).toHaveLength(1);
    await rpc("release_ai_work", [owner, first.lease]);
    expect((await db.query("select * from ai_work_leases")).rows).toHaveLength(0);
    expect(await calls(owner, "ai")).toBe(1);
    const second = await rpc("reserve_ai_work", [owner, 2, 1]);
    expect(second).toMatchObject({ ok: true, remaining: 0 });
    await rpc("release_ai_work", [owner, second.lease]);
    expect(await rpc("reserve_ai_work", [owner, 2, 1])).toMatchObject({ ok: false, reason: "daily" });
    expect(await calls(owner, "ai")).toBe(2);
    expect(await rpc("reserve_ai_work", [editor, 2, 1])).toMatchObject({ ok: true, remaining: 1 });
  });
  it("recovers expired capacity but never refunds an abandoned request", async () => {
    const abandoned = await rpc("reserve_ai_work", [owner, 3, 1]);
    const ttl = (await db.query("select extract(epoch from expires_at-now()) as seconds from ai_work_leases where id=$1", [abandoned.lease])).rows[0]?.seconds;
    expect(Number(ttl)).toBe(300);
    await db.query("update ai_work_leases set expires_at=now()-interval '1 second' where id=$1", [abandoned.lease]);
    const next = await rpc("reserve_ai_work", [owner, 3, 1]);
    expect(next).toMatchObject({ ok: true, remaining: 1 });
    expect((await db.query("select id from ai_work_leases")).rows.map(row => row.id)).toEqual([next.lease]);
    expect(await calls(owner, "ai")).toBe(2);
  });
  it("counts the current UTC day separately and rejects invalid limits", async () => {
    await db.query("insert into owner_work_budgets values($1,(now() at time zone 'UTC')::date-1,'ai',999)", [owner]);
    expect(await rpc("reserve_ai_work", [owner, 1, 1])).toMatchObject({ ok: true, remaining: 0 });
    await rejectsStatement(() => rpc("reserve_ai_work", [owner, 0, 1]), /invalid_limits/);
    await rejectsStatement(() => rpc("reserve_ai_work", [owner, 1, 0]), /invalid_limits/);
  });
  it("keeps service-role quota RPCs inaccessible to authenticated clients", async () => {
    await db.exec("savepoint privileges;set local role authenticated");
    await expect(rpc("reserve_ai_work", [owner, 2, 1])).rejects.toThrow(/permission denied/);
    await db.exec("rollback to privileges");
    await db.exec("set local role service_role");
    expect(await rpc("reserve_ai_work", [owner, 2, 1])).toMatchObject({ ok: true });
  });
});

describe("both export queues share durable admission limits", () => {
  it.each(["pdf_export_jobs", "project_exports"] as const)("enforces the two-job per-user cap when inserting into %s", async table => {
    const legacy = await enqueue("pdf_export_jobs", owner, "running");
    await enqueue("project_exports", owner);
    await rejectsStatement(() => enqueue(table, owner), /export_queue_full/);
    expect(await calls(owner, "export")).toBe(2);
    await db.query("update pdf_export_jobs set status='failed' where id=$1", [legacy]);
    await enqueue(table, owner);
    expect(await calls(owner, "export")).toBe(3);
  });
  it.each(["pdf_export_jobs", "project_exports"] as const)("enforces the five-job global cap when inserting into %s", async table => {
    const release = await enqueue("pdf_export_jobs", owner);
    await enqueue("project_exports", owner, "running");
    await enqueue("pdf_export_jobs", editor);
    await enqueue("project_exports", editor);
    await enqueue("project_exports", viewer);
    await rejectsStatement(() => enqueue(table, outsider), /export_queue_full/);
    expect(await calls(outsider, "export")).toBe(0);
    await db.query("update pdf_export_jobs set status='done' where id=$1", [release]);
    await enqueue(table, outsider);
    expect(await calls(outsider, "export")).toBe(1);
  });
  it.each(["pdf_export_jobs", "project_exports"] as const)("enforces 50 daily admissions across both queues before a new %s job", async table => {
    for (let i = 0; i < 50; i++) {
      const queue = i % 2 ? "pdf_export_jobs" : "project_exports";
      const job = await enqueue(queue, owner);
      await db.query(`update ${queue} set status=$1 where id=$2`, [i % 3 ? "done" : "failed", job]);
    }
    expect(await calls(owner, "export")).toBe(50);
    await rejectsStatement(() => enqueue(table, owner), /export_daily_limit/);
    expect(await calls(owner, "export")).toBe(50);
    await enqueue(table, editor);
    expect(await calls(editor, "export")).toBe(1);
  });
  it("does not double charge completed mirrored artifacts or carry yesterday's budget", async () => {
    await db.query("insert into owner_work_budgets values($1,(now() at time zone 'UTC')::date-1,'export',50)", [owner]);
    const legacy = await enqueue("pdf_export_jobs", owner);
    await db.query("update pdf_export_jobs set status='done' where id=$1", [legacy]);
    await enqueue("project_exports", owner, "done");
    expect(await calls(owner, "export")).toBe(1);
  });
});

describe("upload receipt authorization, identity, expiry and freeze ordering", () => {
  it("locks the project before the receipt, matching freeze's existing row lock", async () => {
    const definition = (await db.query("select pg_get_functiondef('public.commit_upload_receipt(uuid,uuid,uuid,text,text,text,bigint,text,text)'::regprocedure) as body")).rows[0]?.body as string;
    expect(definition.indexOf("public.project_write_guard(pid, actor, session)")).toBeLessThan(definition.indexOf("select * into r from public.pending_uploads"));
    expect(definition).toContain("where object_key=key for update");
  });
  it("freeze-first revokes pending receipts permanently, even after unlock", async () => {
    expect(await issue(1)).toMatchObject({ ok: true });
    expect(await save("r1", "r2", true)).toMatchObject({ ok: true });
    expect(await commit(1)).toMatchObject({ error: "upload_receipt_invalid" });
    expect(await save("r2", "r3", false)).toMatchObject({ ok: true });
    expect(await commit(1)).toMatchObject({ error: "upload_receipt_invalid" });
    expect((await db.query("select * from files")).rows).toHaveLength(0);
    expect((await db.query("select revoked_at,consumed_at from pending_uploads")).rows[0]).toMatchObject({ revoked_at: expect.any(Date), consumed_at: null });
  });
  it("commit-first preserves evidence and exact authorized retries do not restore old pointers", async () => {
    await issue(1); expect(await commit(1)).toMatchObject({ ok: true });
    await issue(2); expect(await commit(2)).toMatchObject({ ok: true });
    await db.query("update pending_uploads set expires_at=now()-interval '1 hour' where object_key=$1", [objectKey(1)]);
    expect(await save("r1", "r2", true)).toMatchObject({ ok: true });
    const before = (await db.query("select * from files order by object_key")).rows;
    expect(await commit(1)).toMatchObject({ ok: true });
    expect((await db.query("select * from files order by object_key")).rows).toEqual(before);
    expect((await db.query("select object_key from files where is_current")).rows[0]?.object_key).toBe(objectKey(2));
  });
  it("rechecks authorization before returning success for a consumed receipt", async () => {
    await issue(1, editor); await commit(1, editor);
    await db.query("update project_members set role='viewer' where user_id=$1", [editor]);
    expect(await commit(1, editor)).toMatchObject({ error: "forbidden" });
    await db.query("delete from project_members where user_id=$1", [editor]);
    expect(await commit(1, editor)).toMatchObject({ error: "not_found" });
  });
  it("binds actor, entity, kind, filename, bytes and declared hash including null tampering", async () => {
    await issue(1, editor);
    const original = receiptArgs(1, editor);
    for (const [field, value] of [[1, owner], [2, outsider], [3, "thumb"], [4, "other.jpg"], [4, null], [6, 101], [6, null], [7, "different-hash"], [7, null]] as const) {
      const args = [...original]; args[field] = value;
      expect(await rpc("commit_upload_receipt", [...args, null])).toMatchObject({ error: "upload_receipt_invalid" });
    }
    expect((await db.query("select * from files")).rows).toHaveLength(0);
    expect((await db.query("select consumed_at from pending_uploads")).rows[0]?.consumed_at).toBeNull();
  });
  it("rejects expired unused receipts, unknown keys and unbounded issuance TTL", async () => {
    expect(await commit(1)).toMatchObject({ error: "upload_receipt_invalid" });
    await issue(1);
    await db.query("update pending_uploads set expires_at=clock_timestamp()-interval '1 second'");
    expect(await commit(1)).toMatchObject({ error: "upload_receipt_expired" });
    expect(await rpc("issue_upload_receipt", [...receiptArgs(2), 901, null])).toMatchObject({ error: "bad_request" });
    expect((await db.query("select * from files")).rows).toHaveLength(0);
  });
});
