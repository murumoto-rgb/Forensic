import { beforeAll,afterAll,beforeEach,afterEach,describe,expect,it,vi } from 'vitest';
import { readFile,readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import Fastify from 'fastify';
const state=vi.hoisted(()=>({db:null as unknown as PGlite,objects:new Map<string,{state:string;sizeBytes:number|null}>(),mutationCalls:0}));
vi.mock('../src/supabase.js',()=>({
 verifyUserJWT:async(token:string)=>token==='invalid'?null:{id:token,email:'synthetic@example.invalid'},
 supabaseAdmin:{rpc:async(name:string,args:Record<string,unknown>)=>{
  state.mutationCalls++;
  try { const entries=Object.entries(args); const result=await state.db.query(`select public.${name}(${entries.map(([k],i)=>`${k} => $${i+1}`).join(',')}) as result`,entries.map(([,v])=>v!==null&&typeof v==='object'?JSON.stringify(v):v));return {data:result.rows[0]?.result,error:null}; }
  catch(error){return {data:null,error};}
 },from:(table:string)=>{
  const filters:[string,unknown][]=[];let columns='*';let max=1000;const ordering:string[]=[];
  const run=async(single=false)=>{try{const r=await state.db.query(`select ${columns} from public.${table}${filters.length?' where '+filters.map(([k],i)=>`${k}=$${i+1}`).join(' and '):''}${ordering.length?' order by '+ordering.join(','):''} limit ${max}`,filters.map(([,v])=>v));return {data:single?r.rows[0]??null:r.rows,error:null};}catch(error){return {data:null,error};}};
  const q={select(s:string){columns=s;return q;},eq(k:string,v:unknown){filters.push([k,v]);return q;},order(k:string,v:{ascending:boolean}){ordering.push(`${k} ${v.ascending?'asc':'desc'}`);return q;},limit(n:number){max=n;return q;},maybeSingle(){return run(true);},then(resolve:unknown,reject:unknown){return run().then(resolve as never,reject as never);}};return q;
 }}
}));
vi.mock('../src/sentry.js',()=>({setRequestUser:()=>{}}));
vi.mock('../src/r2.js',()=>({inspectObject:async(key:string)=>state.objects.get(key)??{state:'missing',sizeBytes:null},deleteObjects:async()=>{},presignedGet:async({objectKey}:{objectKey:string})=>`https://storage.invalid/${objectKey}`,presignedPut:async()=> 'https://storage.invalid/upload',buildObjectKey:({projectId,photoId,kind,uploadId}:Record<string,string>)=>[projectId,photoId,kind,uploadId].filter(Boolean).join('/')}));
import { recoveryRoute } from '../src/routes/recovery.js';
import { workflowRoute } from '../src/routes/workflow.js';
import { projectsRoute } from '../src/routes/projects.js';
import { filesRoute } from '../src/routes/files.js';
import { ProjectSchema } from '@forensic/shared';
const owner='11111111-1111-4111-8111-111111111111', editor='22222222-2222-4222-8222-222222222222',viewer='55555555-5555-4555-8555-555555555555', stranger='66666666-6666-4666-8666-666666666666', pid='33333333-3333-4333-8333-333333333333',photo='44444444-4444-4444-8444-444444444444';
const key=(n:number)=>`${pid}/${photo}/photo/77777777-7777-4777-8777-${String(n).padStart(12,'0')}`;
const photoData={id:photo,sequenceNumber:1,timestamp:'2026-08-30T14:00:00Z',imageFilename:'evidence.jpg',thumbnailFilename:null,positionSource:'none',isPrimary:true,cameraZoom:1,flashMode:'auto',tags:[],pendingSuggestions:[],isFavorite:false,previewRotation:0};
const project=ProjectSchema.parse({id:pid,name:'Evidence',createdAt:'2026-08-30T13:00:00Z',stopped:false,photos:[],trashedPhotos:[],floorPlans:[],buckets:[],manifestSchemaVersion:4});
let app:ReturnType<typeof Fastify>;
async function rpc(name:string,args:unknown[]){const result=await state.db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as result`,args.map(v=>v!==null&&typeof v==='object'?JSON.stringify(v):v));return result.rows[0]!.result as Record<string,any>;}
async function save(rev:string,next:string,body:unknown,actor=owner,session:string|null=null){return rpc('cas_project',[pid,actor,rev,next,body,session]);}
async function commit(n:number,filename='evidence.jpg'){return rpc('commit_project_file',[pid,owner,photo,'photo',filename,key(n),100,null,null]);}
async function versions(){return (await state.db.query('select * from project_versions where project_id=$1 order by created_at,id',[pid])).rows as any[];}
async function completeVersion(){await commit(1);await save('r1','r2',{...project,photos:[{...photoData}]});return (await versions()).find(v=>v.revision==='r2');}
function req(method:string,url:string,payload?:unknown,actor=owner,headers:Record<string,string>={}){return app.inject({method:method as 'GET',url,payload,headers:{authorization:`Bearer ${actor}`,...headers}});}
beforeAll(async()=>{
 state.db=new PGlite();await state.db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to authenticated,service_role;`);
 for(const file of (await readdir(new URL('../../supabase/migrations/',import.meta.url))).filter(n=>n.endsWith('.sql')).sort()){await state.db.exec(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));}
 await state.db.query('insert into auth.users values ($1,$2),($3,$4),($5,$6),($7,$8)',[owner,'owner@example.invalid',editor,'editor@example.invalid',viewer,'viewer@example.invalid',stranger,'stranger@example.invalid']);
 app=Fastify();await app.register(recoveryRoute);await app.register(workflowRoute);await app.register(projectsRoute);await app.register(filesRoute);await app.ready();
},30000);
afterAll(async()=>{await app?.close();await state.db?.close();});
beforeEach(async()=>{await state.db.exec('begin');state.objects.clear();state.mutationCalls=0;await rpc('cas_project',[pid,owner,null,'r1',project,null]);await state.db.query('insert into project_members(project_id,user_id,role) values ($1,$2,\'editor\'),($1,$3,\'viewer\')',[pid,editor,viewer]);});
afterEach(async()=>{await state.db.exec('rollback');});
describe('transactional evidence recovery',()=>{
 it('rejects stale writes and viewer writes at the DB boundary',async()=>{
  expect((await save('r1','r2',{...project,name:'saved'})).ok).toBe(true);
  expect((await save('r1','r3',{...project,name:'stale'})).error).toBe('revision_mismatch');
  expect((await save('r2','r3',project,viewer)).error).toBe('forbidden');
  expect((await state.db.query('select revision from projects')).rows[0]?.revision).toBe('r2');
 });
 it('serializes live lock acquisition with saves, including same-user tabs',async()=>{
  expect((await rpc('acquire_project_lock',[pid,editor,'editor@example.invalid','web','tab-a'])).ok).toBe(true);
  expect((await save('r1','r2',project)).error).toBe('locked');
  expect((await save('r1','r2',project,editor,'tab-b')).error).toBe('locked');
  expect((await rpc('acquire_project_lock',[pid,owner,'owner@example.invalid','web','other'])).error).toBe('locked');
  expect((await save('r1','r2',project,editor,'tab-a')).ok).toBe(true);
 });
 it('rejects frozen edits at DB boundary and only permits owner pure unlock',async()=>{
  await save('r1','r2',{...project,isFrozen:true});
  expect((await save('r2','r3',{...project,isFrozen:false,name:'changed'})).error).toBe('project_frozen');
  expect((await save('r2','r3',project,editor)).error).toBe('forbidden');
  expect((await commit(1)).error).toBe('project_frozen');
  expect((await save('r2','r3',project)).ok).toBe(true);
 });
 it('protects exact historical bytes and restores pointers atomically',async()=>{
  const v=await completeVersion();await commit(2);await save('r2','r3',{...project,name:'newer',photos:[photoData]});
  expect((await state.db.query('select object_key from current_project_files')).rows[0]?.object_key).toBe(key(2));
  const restored=await rpc('restore_project_version',[pid,owner,v.id,'r3','r4',[key(1)],null]);expect(restored.ok).toBe(true);
  expect((await state.db.query('select object_key from current_project_files')).rows[0]?.object_key).toBe(key(1));
  await commit(2); // stale retry must not undo restore
  expect((await state.db.query('select object_key from current_project_files')).rows[0]?.object_key).toBe(key(1));
  const old=(await versions()).find(x=>x.id===v.id);expect(old.assets[0].objectKey).toBe(key(1));
 });
 it('checkpoints only complete asset sets and preserves incomplete history',async()=>{
  await save('r1','r2',{...project,photos:[photoData]});
  expect((await versions()).filter(v=>v.revision==='r2')).toHaveLength(1);
  await commit(1);
  const checkpoints=(await versions()).filter(v=>v.revision==='r2');
  expect(checkpoints).toHaveLength(2);
  expect(checkpoints.filter(v=>v.assets[0].objectKey===null)).toHaveLength(1);
  expect(checkpoints.filter(v=>v.assets[0].objectKey===key(1))).toHaveLength(1);
  await commit(1);expect((await versions()).filter(v=>v.revision==='r2')).toHaveLength(2);
 });
 it('does not mistake a differently named pending upload for the manifest asset',async()=>{
  await completeVersion();await commit(2,'replacement.jpg');
  expect((await state.db.query('select object_key from current_project_files')).rows[0]?.object_key).toBe(key(1));
  await save('r2','r3',{...project,photos:[{...photoData,imageFilename:'replacement.jpg'}]});
  expect((await state.db.query('select object_key from current_project_files')).rows[0]?.object_key).toBe(key(2));
 });
 it('keeps incomplete history readable and refuses unverifiable restore with no changes',async()=>{
  await save('r1','r2',{...project,photos:[photoData]});const v=(await versions()).find(x=>x.revision==='r2');
  expect(v.assets[0].objectKey).toBeNull();
  expect((await rpc('restore_project_version',[pid,owner,v.id,'r2','r3',[],null])).error).toBe('assets_unavailable');
  expect((await state.db.query('select revision from projects')).rows[0]?.revision).toBe('r2');
 });
 it('restores only the requested project and blocks frozen/stale restore',async()=>{
  const v=await completeVersion();
  expect((await rpc('restore_project_version',[pid,owner,v.id,'stale','r3',[key(1)],null])).error).toBe('revision_mismatch');
  await save('r2','r3',{...project,photos:[photoData],isFrozen:true});
  expect((await rpc('restore_project_version',[pid,owner,v.id,'r3','r4',[key(1)],null])).error).toBe('project_frozen');
 });
 it('does not let an editor freeze by restoring a finalized historical version',async()=>{
  await save('r1','r2',{...project,isFrozen:true});const v=(await versions()).find(x=>x.revision==='r2');
  await save('r2','r3',project);
  expect((await rpc('restore_project_version',[pid,editor,v.id,'r3','r4',[],null])).error).toBe('forbidden');
 });
 it('prevents historical deletion/rewrites even with service-role table grants',async()=>{
  await completeVersion();await state.db.exec('savepoint immutable');
  await expect(state.db.query('update files set size_bytes=12')).rejects.toThrow('immutable');await state.db.exec('rollback to immutable');
  await expect(state.db.query('delete from files')).rejects.toThrow('retained');await state.db.exec('rollback to immutable');
  await expect(state.db.query('update project_versions set manifest=\'{}\'')).rejects.toThrow('immutable');await state.db.exec('rollback to immutable');
 });
 it('cascades retained files only on an authorized trashed-project deletion',async()=>{
  await completeVersion();await save('r2','r3',{...project,isDeleted:true});
  expect((await rpc('delete_project_evidence',[pid,owner,'r2',null])).error).toBe('revision_mismatch');
  const deleted=await rpc('delete_project_evidence',[pid,owner,'r3',null]);expect(deleted.objectKeys).toEqual([key(1)]);
  expect((await state.db.query('select * from files')).rows).toHaveLength(0);expect((await state.db.query('select * from project_versions')).rows).toHaveLength(0);
 });
 it('blocks authenticated direct execution of service-only recovery RPCs',async()=>{
  await state.db.exec('savepoint perms;set local role authenticated');
  await expect(rpc('restore_project_version',[pid,owner,crypto.randomUUID(),'r1','r2',[],null])).rejects.toThrow('permission denied');await state.db.exec('rollback to perms');
 });
});
describe('real routes, PostgreSQL state, fake object store',()=>{
 it('health distinguishes registered, missing, and unverified; unauthorized users see no metadata',async()=>{
  await completeVersion();
  expect((await req('GET',`/v1/projects/${pid}/health`)).json().assets[0].state).toBe('registered');
  expect((await req('GET',`/v1/projects/${pid}/health?verify=true`)).json().assets[0].state).toBe('missing');
  state.objects.set(key(1),{state:'unverified',sizeBytes:null});
  const health=(await req('GET',`/v1/projects/${pid}/health?verify=true`)).json();expect(health.assets[0].state).toBe('unverified');expect(health.missing).toBe(0);
  expect((await req('GET',`/v1/projects/${pid}/health`,undefined,stranger)).statusCode).toBe(404);
  expect((await app.inject({url:`/v1/projects/${pid}/health`})).statusCode).toBe(401);
 });
 it('lists compact version metadata and guards filename-scoped binary recovery',async()=>{
  await completeVersion();
  const list=await req('GET',`/v1/projects/${pid}/versions`,undefined,viewer);
  expect(list.statusCode).toBe(200);expect(list.json().versions[0]).toHaveProperty('restorable');
  expect((await req('GET',`/v1/projects/${pid}/versions`,undefined,stranger)).statusCode).toBe(404);
  const endpoint=`/v1/projects/${pid}/files/${photo}/photo`;
  expect((await req('GET',endpoint+'?filename=wrong.jpg')).statusCode).toBe(409);
  expect((await req('GET',endpoint+'?filename=evidence.jpg',undefined,viewer)).json().url).toContain(key(1));
  expect((await req('GET',endpoint,undefined,stranger)).statusCode).toBe(404);
 });
 it('never writes on an unavailable storage restore, viewer restore, or stale revision',async()=>{
  const v=await completeVersion();const url=`/v1/projects/${pid}/versions/restore`;const body={versionId:v.id,expectedRevision:'r2'};
  expect((await req('POST',url,body)).json().error).toBe('assets_unavailable');
  state.objects.set(key(1),{state:'available',sizeBytes:100});
  expect((await req('POST',url,body,viewer)).statusCode).toBe(403);
  expect((await req('POST',url,{...body,expectedRevision:'r1'})).statusCode).toBe(409);
  expect((await req('POST',url,body)).statusCode).toBe(200);
 });
 it('enforces upload upgrade and byte size rather than trusting client metadata',async()=>{
  const url=`/v1/projects/${pid}/files/commit`;const body={objectKey:key(1),photoId:photo,kind:'photo',sizeBytes:100};
  expect((await req('POST',url,body)).statusCode).toBe(426);
  state.objects.set(key(1),{state:'available',sizeBytes:99});
  expect((await req('POST',url,{...body,immutable:true,sourceFilename:'evidence.jpg'})).statusCode).toBe(409);
  expect((await state.db.query('select * from files')).rows).toHaveLength(0);
 });
 it('uses CAS for legacy manifest saves and rechecks locks after route preflight',async()=>{
  await rpc('acquire_project_lock',[pid,editor,'editor@example.invalid','web','tab-a']);
  const response=await req('PUT',`/v1/projects/${pid}`,{project:{...project,name:'overwrite'},expectedRevision:'r1'});
  expect(response.statusCode).toBe(409);expect(response.json().error).toBe('locked');
 });
 it('rejects future manifests instead of silently dropping unknown fields',async()=>{
  const response=await req('PUT',`/v1/projects/${pid}`,{project:{...project,manifestSchemaVersion:999,newEvidenceField:'do not lose'},expectedRevision:'r1'});
  expect(response.statusCode).toBe(409);expect(response.json().error).toBe('manifest_schema_unsupported');
  expect((await state.db.query('select revision from projects')).rows[0]?.revision).toBe('r1');
 });
 it.each([false,true].flatMap(merge=>[3,4].map(version=>({merge,version}))))('rejects old v$version codecs on v4 projects, merge=$merge, before mutation',async({merge,version})=>{
  const current={...project,inspectionChecklist:[{id:photo,label:'Keep evidence',isComplete:true}],inspectionSessions:[{id:photo,startedAt:'2026-08-30T13:00:00Z',endedAt:null}],reportLayout:{perPage:6,groupByBucket:true,includeMetadataTable:true}};
  await save('r1','r2',current);
  const old={...project,name:'Old-client overwrite',manifestSchemaVersion:version} as Record<string,unknown>;
  delete old.inspectionChecklist;delete old.inspectionSessions;delete old.reportLayout;
  const historyBefore=(await versions()).length;
  const response=await req('PUT',`/v1/projects/${pid}`,{project:old,expectedRevision:'r2',...(merge?{baseManifest:{...old,name:project.name}}:{})});
  expect(response.statusCode).toBe(426);expect(response.json().error).toBe('upgrade_required');expect(state.mutationCalls).toBe(0);
  const stored=(await state.db.query('select manifest,revision from projects where id=$1',[pid])).rows[0]!;
  expect(stored.revision).toBe('r2');expect(stored.manifest).toEqual(current);expect(await versions()).toHaveLength(historyBefore);
  // Read access remains available to older clients and viewers.
  expect((await req('GET',`/v1/projects/${pid}`,undefined,viewer)).statusCode).toBe(200);
 });
 it.each([false,true])('accepts an explicit v4 write on merge=%s without requiring optional reportLayout',async(merge)=>{
  const modern={...project,name:'Modern edit'} as Record<string,unknown>;delete modern.reportLayout;
  const response=await req('PUT',`/v1/projects/${pid}`,{project:modern,expectedRevision:'r1',...(merge?{baseManifest:project}:{})});
  expect(response.statusCode,response.body).toBe(200);expect(state.mutationCalls).toBe(1);
  expect((await state.db.query('select name from projects where id=$1',[pid])).rows[0]?.name).toBe('Modern edit');
 });
 it('allows an old codec to save a still-v3 project',async()=>{
  const old={...project,manifestSchemaVersion:3} as Record<string,unknown>;delete old.inspectionChecklist;delete old.inspectionSessions;delete old.reportLayout;
  await save('r1','r2',old);
  const response=await req('PUT',`/v1/projects/${pid}`,{project:{...old,name:'Legacy edit'},expectedRevision:'r2'});
  expect(response.statusCode,response.body).toBe(200);
 });
 it('workflow is private and first-write/stale CAS cannot clobber another update',async()=>{
  const library={savedSearches:[],inspectionPresets:[]};const first=await req('PUT','/v1/me/workflow',{library,expectedRevision:null});expect(first.statusCode).toBe(200);
  expect((await req('PUT','/v1/me/workflow',{library,expectedRevision:null})).statusCode).toBe(409);
  expect((await req('GET','/v1/me/workflow',undefined,viewer)).json().revision).toBeNull();
 });
 it('search applies membership, literal search, favorites, dates and pagination',async()=>{
  await save('r1','r2',{...project,photos:[{...photoData,isFavorite:true,userCaption:'Crack evidence'}]});
  const filter={query:'Crack',favoritesOnly:true,fromDate:'2026-08-01',toDate:'2026-08-31'};
  expect((await req('POST','/v1/search',{filter},viewer)).json().hits).toHaveLength(1);
  expect((await req('POST','/v1/search',{filter},stranger)).json().hits).toHaveLength(0);
  expect((await req('POST','/v1/search',{filter:{...filter,query:'%'}})).json().hits).toHaveLength(0);
 });
 it('rejects impossible search dates at the authenticated API boundary',async()=>{
  for (const fromDate of ['2026-02-31','2026-99-99','2025-02-29']) {
   expect((await req('POST','/v1/search',{filter:{query:'',fromDate,toDate:null,favoritesOnly:false}})).statusCode).toBe(400);
  }
  expect((await req('POST','/v1/search',{filter:{query:'',fromDate:'2024-02-29',toDate:null,favoritesOnly:false}})).statusCode).toBe(200);
 });
});
