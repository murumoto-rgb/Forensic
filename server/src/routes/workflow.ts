import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { SearchFilterSchema, WorkflowLibrarySchema } from '@forensic/shared';
import { authPlugin } from '../middleware/auth.js';
import { supabaseAdmin } from '../supabase.js';
import { sendTransactionError } from '../projectTransactions.js';

const putSchema=z.object({library:WorkflowLibrarySchema,expectedRevision:z.string().max(200).nullable()});
const searchSchema=z.object({filter:SearchFilterSchema,offset:z.number().int().min(0).max(100000).default(0),limit:z.number().int().min(1).max(100).default(50)});
export const workflowRoute: FastifyPluginAsync=async(app)=>{
  await app.register(authPlugin);
  app.get('/v1/me/workflow',async(request)=>{
    const {data,error}=await supabaseAdmin.from('user_workflow').select('library,revision').eq('user_id',request.user.id).maybeSingle();
    if(error) throw error;
    return data??{library:{savedSearches:[],inspectionPresets:[]},revision:null};
  });
  app.put('/v1/me/workflow',{bodyLimit:1024*1024},async(request,reply)=>{
    const body=putSchema.safeParse(request.body);
    if(!body.success) return reply.code(400).send({error:'bad_request',message:'Invalid workflow library',details:body.error.issues});
    const revision=crypto.randomUUID();
    const {data,error}=await supabaseAdmin.rpc('cas_user_workflow',{actor:request.user.id,body:body.data.library,expected:body.data.expectedRevision,next_revision:revision});
    if(error) throw error;
    if(!data) throw new Error('Workflow transaction returned no result');
    if(sendTransactionError(reply,data)) return;
    return {revision};
  });
  app.post('/v1/search',{bodyLimit:16384},async(request,reply)=>{
    const body=searchSchema.safeParse(request.body);
    if(!body.success) return reply.code(400).send({error:'bad_request',message:'Invalid search filter'});
    const {filter,offset,limit}=body.data;
    if(filter.fromDate && filter.toDate && filter.fromDate>filter.toDate) return reply.code(400).send({error:'bad_request',message:'Start date must be before end date'});
    const {data,error}=await supabaseAdmin.rpc('search_project_evidence',{actor:request.user.id,term:filter.query.trim(),from_date:filter.fromDate,to_date:filter.toDate,favorites:filter.favoritesOnly,page_offset:offset,page_limit:limit});
    if(error) throw error;
    const hits=(data??[]) as unknown[];
    return {hits:hits.slice(0,limit),nextOffset:hits.length>limit?offset+limit:null};
  });
};
