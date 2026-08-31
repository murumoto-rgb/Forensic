import type {
  Bucket, InspectionReportLayout, Project, ProjectExtraVocabulary, ProjectTagSelection,
} from "./manifest.js";
import type { FileKind, GetManifestResponse } from "./api.js";

export interface SearchFilter {
  query: string;
  fromDate: string | null;
  toDate: string | null;
  favoritesOnly: boolean;
}
export interface SavedSearch { id: string; name: string; filter: SearchFilter }
export interface InspectionPreset {
  id: string;
  name: string;
  projectNamePrefix: string;
  projectAddress: string | null;
  aiInstructions: string | null;
  tagSelection: ProjectTagSelection | null;
  aiExtraVocabulary: ProjectExtraVocabulary | null;
  buckets: Bucket[];
  checklist: string[];
  reportLayout: InspectionReportLayout;
}
export interface WorkflowLibrary {
  savedSearches: SavedSearch[];
  inspectionPresets: InspectionPreset[];
}
export interface GetWorkflowLibraryResponse { library: WorkflowLibrary; revision: string | null }
export interface PutWorkflowLibraryRequest { library: WorkflowLibrary; expectedRevision: string | null }
export interface PutWorkflowLibraryResponse { revision: string }

export interface ProjectSearchHit {
  projectId: string;
  projectName: string;
  projectAddress: string | null;
  photoId: string | null;
  sequenceNumber: number | null;
  caption: string | null;
  timestamp: string;
}
export interface ProjectSearchResponse {
  hits: ProjectSearchHit[];
  nextOffset: number | null;
}
export interface ProjectHealthAsset {
  entityId: string;
  kind: FileKind;
  filename: string;
  objectKey: string | null;
  state: "registered" | "available" | "missing" | "unverified";
}
export interface ProjectHealthResponse {
  projectId: string;
  revision: string;
  checkedAt: string;
  verification: "registry" | "object-store";
  assets: ProjectHealthAsset[];
  expected: number;
  registered: number;
  available: number;
  missing: number;
}
export interface ProjectVersionSummary {
  id: string;
  revision: string;
  createdAt: string;
  photoCount: number;
  planCount: number;
  /** Only true when the snapshot includes every required immutable asset. */
  restorable: boolean;
  missingAssetCount: number;
}
export interface ListProjectVersionsResponse { versions: ProjectVersionSummary[] }
export interface GetProjectVersionResponse {
  version: ProjectVersionSummary;
  project: Project;
}
export interface RestoreProjectVersionRequest { versionId: string; expectedRevision: string }
export type RestoreProjectVersionResponse = GetManifestResponse;

/** Preview first; callers show a diff and ask the owner to apply this snapshot.
 * Preserves existing evidence, captions and bucket assignments. Preset buckets
 * are appended with fresh IDs so repeats cannot corrupt existing assignments. */
export function applyInspectionPreset(project: Project, preset: InspectionPreset,
  uuid: () => string = () => crypto.randomUUID()): Project {
  if (project.isFrozen) return project;
  return {
    ...project,
    projectAddress: project.projectAddress || preset.projectAddress,
    aiInstructions: preset.aiInstructions,
    tagSelection: preset.tagSelection,
    aiExtraVocabulary: preset.aiExtraVocabulary,
    buckets: [...project.buckets, ...preset.buckets.map((b, i) => ({
      ...b, id: uuid(), sortOrder: project.buckets.length + i,
    }))],
    inspectionChecklist: [...project.inspectionChecklist,
      ...preset.checklist.map((label) => ({ id: uuid(), label, isComplete: false }))],
    reportLayout: preset.reportLayout,
    manifestSchemaVersion: 4,
  };
}

export function setInspectionSession(project: Project, action: "start" | "stop",
  now = new Date().toISOString(), uuid: () => string = () => crypto.randomUUID()): Project {
  if (project.isFrozen) return project;
  const open = project.inspectionSessions.some((s) => s.endedAt === null);
  if (action === "start") {
    if (open) return project;
    return { ...project, startedAt: project.startedAt ?? now,
      lastResumedAt: project.startedAt ? now : project.lastResumedAt, stopped: false,
      inspectionSessions: [...project.inspectionSessions, { id: uuid(), startedAt: now, endedAt: null }],
      manifestSchemaVersion: 4 };
  }
  return { ...project, stopped: true, lastStoppedAt: now,
    inspectionSessions: project.inspectionSessions.map((s) => s.endedAt === null ? { ...s, endedAt: now } : s),
    manifestSchemaVersion: 4 };
}
