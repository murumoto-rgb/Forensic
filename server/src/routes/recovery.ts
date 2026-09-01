import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { ProjectSchema, type Project, type ProjectHealthResponse, type ProjectHealthAsset, type ProjectVersionSummary } from '@forensic/shared';
import { authPlugin } from '../middleware/auth.js';
import { supabaseAdmin } from '../supabase.js';
import { assertProjectAccess, assertProjectMutable, sendAccessError } from '../access.js';
import { inspectObject } from '../r2.js';
import { clientSession, sendTransactionError } from '../projectTransactions.js';

interface Asset { entityId:string;kind:ProjectHealthAsset['kind'];filename:string;objectKey:string|null;immutable:boolean;sizeBytes:number|null }
interface Version { id:string;revision:string;created_at:string;manifest:Project;assets:Asset[] }
function summary(v:Version):ProjectVersionSummary {
  const missingAssetCount=v.assets.filter(a=>!a.objectKey || !a.immutable).length;
  return {id:v.id,revision:v.revision,createdAt:v.created_at,photoCount:(v.manifest.photos??[]).length,
    planCount:(v.manifest.floorPlans??[]).length,restorable:missingAssetCount===0,missingAssetCount};
}
/** Small worker pool: bounds storage requests even for very large manifests. */
export async function mapBounded<T,R>(values:T[],fn:(value:T)=>Promise<R>,concurrency=6):Promise<R[]> {
  const result:R[]=new Array(values.length); let next=0;
  await Promise.all(Array.from({length:Math.min(concurrency,values.length)},async()=>{
    while(next<values.length){const i=next++;result[i]=await fn(values[i]!);}
  }));return result;
}
const restoreSchema=z.object({versionId:z.string().uuid(),expectedRevision:z.string().min(1).max(200)});
export const recoveryRoute:FastifyPluginAsync=async(app)=>{
  await app.register(authPlugin);
  // No private version/file metadata leaves this plugin without project access.
  app.addHook('preHandler',async(request,reply)=>{
    const {id} = request.params as {id:string};
    if(!z.string().uuid().safeParse(id).success) return reply.code(400).send({error:'bad_request',message:'Invalid project ID'});
    try {await assertProjectAccess(request.user.id,id,'viewer',request);}
    catch(error){if(sendAccessError(reply,error)) return;throw error;}
  });
  app.get<{Params:{id:string};Querystring:{verify?:string}}>('/v1/projects/:id/health',async(request)=>{
    const {data,error}=await supabaseAdmin.rpc('project_health_snapshot',{pid:request.params.id});
    if(error) throw error;
    if(!data) throw Object.assign(new Error('Project not found'),{statusCode:404});
    const row=data as {revision:string;assets:Asset[]};
    const verify=request.query.verify==='true';
    const assets:ProjectHealthAsset[]=await mapBounded(row.assets,async(a)=>{
      let state:ProjectHealthAsset['state']=a.objectKey?'registered':'missing';
      if(verify && a.objectKey){
        const result=await inspectObject(a.objectKey);
        state=result.state==='available' && result.sizeBytes!==a.sizeBytes?'unverified':result.state;
      }
      return {entityId:a.entityId,kind:a.kind,filename:a.filename,objectKey:a.objectKey,state};
    });
    return {projectId:request.params.id,revision:row.revision,checkedAt:new Date().toISOString(),verification:verify?'object-store':'registry',assets,
      expected:assets.length,registered:assets.filter(a=>a.objectKey!==null).length,available:assets.filter(a=>a.state==='available').length,missing:assets.filter(a=>a.state==='missing').length} satisfies ProjectHealthResponse;
  });
  app.get<{Params:{id:string}}>('/v1/projects/:id/versions',async(request)=>{
    const {data,error}=await supabaseAdmin.rpc('list_project_versions',{pid:request.params.id});
    if(error) throw error;
    return {versions:data??[]};
  });
  app.get<{Params:{id:string;versionId:string}}>('/v1/projects/:id/versions/:versionId',async(request,reply)=>{
    if(!z.string().uuid().safeParse(request.params.versionId).success) return reply.code(400).send({error:'bad_request',message:'Invalid version ID'});
    const {data,error}=await supabaseAdmin.from('project_versions').select('id,revision,created_at,manifest,assets').eq('project_id',request.params.id).eq('id',request.params.versionId).maybeSingle();
    if(error) throw error;
    if(!data) return reply.code(404).send({error:'not_found',message:'Version not found'});
    const v=data as Version;return {version:summary(v),project:ProjectSchema.parse(v.manifest)};
  });
  app.post<{Params:{id:string}}>('/v1/projects/:id/versions/restore',async(request,reply)=>{
    const body=restoreSchema.safeParse(request.body);
    if(!body.success) return reply.code(400).send({error:'bad_request',message:'Invalid restore request'});
    try {await assertProjectMutable(request.user.id,request.params.id,request);}catch(error){if(sendAccessError(reply,error)) return;throw error;}
    const {data,error}=await supabaseAdmin.from('project_versions').select('id,revision,created_at,manifest,assets').eq('project_id',request.params.id).eq('id',body.data.versionId).maybeSingle();
    if(error) throw error;
    if(!data) return reply.code(404).send({error:'not_found',message:'Version not found'});
    const v=data as Version;
    if(!summary(v).restorable){sendTransactionError(reply,{error:'assets_unavailable'});return;}
    const verified=await mapBounded(v.assets,async(a)=>{
      if(!a.objectKey || !a.immutable) return null;
      const object=await inspectObject(a.objectKey);
      return object.state==='available' && object.sizeBytes===a.sizeBytes?a.objectKey:null;
    });
    if(verified.some(key=>key===null)){sendTransactionError(reply,{error:'assets_unavailable'});return;}
    const {data:result,error:writeError}=await supabaseAdmin.rpc('restore_project_version',{pid:request.params.id,actor:request.user.id,version_id:body.data.versionId,expected:body.data.expectedRevision,next_revision:crypto.randomUUID(),verified_keys:verified,session:clientSession(request)});
    if(writeError) throw writeError;
    if(!result) throw new Error('Restore returned no result');
    if(sendTransactionError(reply,result)) return;
    const role=await assertProjectAccess(request.user.id,request.params.id,'viewer',request);
    return {project:ProjectSchema.parse(result.project),revision:result.revision,role};
  });
};
