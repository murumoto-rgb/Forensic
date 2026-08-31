import type { FastifyReply, FastifyRequest } from 'fastify';
import type { Project } from '@forensic/shared';
import { supabaseAdmin } from './supabase.js';

export interface TransactionResult { ok?: boolean; error?: string; revision?: string; project?: Project; lock?: unknown }
export function clientSession(request: FastifyRequest): string | null {
  const value = request.headers['x-client-session'];
  return typeof value === 'string' && value.length <= 200 ? value : null;
}
export function sendTransactionError(reply: FastifyReply, result: TransactionResult): boolean {
  if (!result.error) return false;
  const status = result.error === 'not_found' ? 404 : result.error === 'forbidden' ? 403 : result.error === 'bad_request' ? 400 : 409;
  reply.code(status).send({ error: result.error, message: {
    locked: 'Another editing session holds this project. Acquire the edit lock before saving.',
    project_frozen: 'Project is finalized. Unlock it before making changes.',
    assets_unavailable: 'This version has missing or unverifiable evidence and cannot be restored.',
    revision_mismatch: 'Project changed. Refresh and review before retrying.',
  }[result.error] ?? 'The operation could not be completed.' });
  return true;
}
export async function saveProject(request: FastifyRequest, id: string, expected: string | null, revision: string, project: Project): Promise<TransactionResult> {
  const {data,error}=await supabaseAdmin.rpc('cas_project',{pid:id,actor:request.user.id,expected,next_revision:revision,body:project,session:clientSession(request)});
  if(error) throw error;
  if(!data) throw new Error('Project transaction returned no result');
  return data as TransactionResult;
}
