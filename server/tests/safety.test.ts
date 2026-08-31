import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const OWNER = "00000000-0000-0000-0000-000000000001";

describe("audit safety migration", () => {
  it("makes CAS first write and stale write mutually exclusive", async () => {
    const db = new PGlite();
    await db.exec(`
      create role anon nologin;
      create role authenticated nologin;
      create role service_role nologin bypassrls;
      create schema auth;
      create table auth.users(id uuid primary key, email text);
      create function auth.uid() returns uuid language sql stable as
        $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
      grant usage on schema public, auth to authenticated, service_role;
    `);
    for (const name of ["0001_initial.sql", "0002_grant_service_role.sql", "0003_files_table.sql", "0004_app_config_table.sql", "0005_audit_log.sql", "0006_project_locks.sql", "0007_pdf_export_jobs.sql", "0008_pdf_export_options.sql", "0009_pdf_export_progress.sql", "0010_user_prefs.sql", "0011_project_exports.sql", "0012_project_exports_progress.sql", "0013_project_locks_session.sql", "0014_collaboration_roles.sql", "0015_seed_first_admin.sql", "0016_audit_safety.sql", "0017_recovery_workflow.sql", "0018_resource_limits.sql", "0019_upload_receipts.sql"]) {
      await db.exec(await readFile(new URL(`../../supabase/migrations/${name}`, import.meta.url), "utf8"));
    }
    await db.exec(`insert into auth.users values ('${OWNER}', 'owner@example.invalid')`);

    const project = "00000000-0000-0000-0000-000000000002";
    const entity = "00000000-0000-0000-0000-000000000003";
    await db.exec(`insert into public.projects(id,owner_id,name,manifest,manifest_schema_version,revision) values ('${project}','${OWNER}','p','{"id":"${project}","name":"p","photos":[],"floorPlans":[]}',2,'p1')`);
    const issued = await db.query(`select public.issue_upload_receipt('${project}','${OWNER}','${entity}','photo','original.jpg','${project}/${entity}/photo/00000000-0000-0000-0000-000000000004',12,'sha',900,null) as result`);
    const substituted = await db.query(`select public.commit_upload_receipt('${project}','${OWNER}','${entity}','photo','tampered.jpg','${project}/${entity}/photo/00000000-0000-0000-0000-000000000004',12,'sha',null) as result`);
    expect(issued.rows[0].result.ok).toBe(true);
    expect(substituted.rows[0].result).toEqual({ error: "upload_receipt_invalid" });
    await db.exec(`update public.projects set manifest = manifest || '{"isFrozen":true}'::jsonb where id='${project}'`);
    await db.exec(`update public.projects set manifest = manifest || '{"isFrozen":false}'::jsonb where id='${project}'`);
    const revoked = await db.query(`select public.commit_upload_receipt('${project}','${OWNER}','${entity}','photo','original.jpg','${project}/${entity}/photo/00000000-0000-0000-0000-000000000004',12,'sha',null) as result`);
    expect(revoked.rows[0].result).toEqual({ error: "upload_receipt_invalid" });

    const first = await db.query(`select public.cas_user_prefs('${OWNER}', '{}', null, 'r1') as result`);
    const stale = await db.query(`select public.cas_user_prefs('${OWNER}', '{"x":1}', null, 'r2') as result`);
    expect(first.rows[0].result).toEqual({ ok: true, revision: "r1" });
    expect(stale.rows[0].result).toEqual({ ok: false, current_revision: "r1" });
    await db.close();
  // Starting PostgreSQL/WASM and applying the migration history is not a latency benchmark.
  }, 30_000);

  it("keeps new upload keys unique while preserving legacy keys", async () => {
    process.env.SUPABASE_URL ??= "http://127.0.0.1:9";
    process.env.SUPABASE_SECRET_KEY ??= "test-secret";
    process.env.SUPABASE_PUBLISHABLE_KEY ??= "test-publishable";
    process.env.R2_ACCOUNT_ID ??= "test-account";
    process.env.R2_ACCESS_KEY_ID ??= "test-access";
    process.env.R2_SECRET_ACCESS_KEY ??= "test-secret";
    process.env.R2_BUCKET ??= "test-bucket";
    const { buildObjectKey, presignedPut } = await import("../src/r2.js");
    const legacy = buildObjectKey({ projectId: OWNER, photoId: OWNER, kind: "photo" });
    const generated = buildObjectKey({ projectId: OWNER, photoId: OWNER, kind: "photo", uploadId: "upload-1" });
    expect(generated).toBe(`${legacy}/upload-1`);
    expect(generated).not.toBe(legacy);
    const upload = new URL(await presignedPut({ objectKey: generated, contentType: "image/jpeg", contentLength: 100, expiresInSeconds: 60, ifNoneMatch: "*" }));
    expect(upload.searchParams.get("X-Amz-SignedHeaders")?.split(";")).toContain("if-none-match");
  });
});
