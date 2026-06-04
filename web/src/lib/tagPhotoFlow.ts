import type {
  AITagPhotoModel,
  AIPhotoAnalysis,
  ValidationVocabulary,
} from "@forensic/shared";
import {
  compileUserPrompt,
  parseAIPhotoAnalysis,
  repairUserPromptText,
  validateAIResponse,
} from "@forensic/shared";
import { api } from "./api";

/**
 * Combine `api.tagPhoto` + `parseAIPhotoAnalysis` + (optional)
 * validator + (optional) one-shot repair retry into one call.
 * Both the single-photo "Re-tag with AI" button and the batch
 * runner use this so the validate + repair behaviour stays
 * consistent across surfaces.
 *
 * `vocabulary` is null when the caller can't or doesn't want to
 * validate (no project tag selection, an earlier prep step
 * couldn't resolve it). With it, the validator's complaints
 * land on `analysis.validationErrors` and — if the first response
 * had any AND it parsed — a single repair retry runs against the
 * proxy endpoint with the prior response + the validator's
 * complaints embedded in the user message.
 *
 * Mirrors iOS's `ClaudeTaggingService.tag(...)`'s repair logic:
 * fall back to the first result if the repair call throws or
 * returns a parse-failed response, so the engineer at least
 * sees what the model produced.
 *
 * The proxy endpoint is single-turn today, so the prior
 * response is wrapped into the second call's `userText` rather
 * than passed as a true assistant-role message. Not as
 * effective as multi-turn but doesn't require a server change.
 * Phase 5 can promote to true multi-turn if the model's
 * repair-rate isn't satisfactory.
 */
export async function tagPhotoWithValidation(args: {
  projectId: string;
  photoId: string;
  imageFilename: string;
  model: AITagPhotoModel;
  systemPrompt: string;
  vocabulary: ValidationVocabulary | null;
}): Promise<TagPhotoResult> {
  const { projectId, photoId, imageFilename, model, systemPrompt, vocabulary } =
    args;

  // First call.
  const userText = compileUserPrompt(imageFilename);
  const firstResp = await api.tagPhoto({
    projectId,
    photoId,
    model,
    systemPrompt,
    userText,
  });
  const firstAnalysis = parseAIPhotoAnalysis({
    rawText: firstResp.rawText,
    fallbackPhotoID: imageFilename,
  });

  // Without a vocabulary we can't validate; without a parsed
  // response we can't even know WHAT to repair.
  if (!vocabulary || firstAnalysis.parseFailed) {
    return { analysis: firstAnalysis, didRepair: false };
  }

  // Run validator → populate validationErrors.
  firstAnalysis.validationErrors = validateAIResponse({
    analysis: firstAnalysis,
    vocabulary,
  });
  if (firstAnalysis.validationErrors.length === 0) {
    return { analysis: firstAnalysis, didRepair: false };
  }

  // One-shot repair retry. Embed the prior raw response + the
  // validator's bullets in the second call's userText.
  const priorBlock = firstAnalysis.rawResponse
    ? `\n\nYour previous response was:\n${firstAnalysis.rawResponse}`
    : "";
  const repairUserText =
    userText + priorBlock + "\n\n" + repairUserPromptText(firstAnalysis.validationErrors);

  let repairAnalysis: AIPhotoAnalysis;
  try {
    const repairResp = await api.tagPhoto({
      projectId,
      photoId,
      model,
      systemPrompt,
      userText: repairUserText,
    });
    repairAnalysis = parseAIPhotoAnalysis({
      rawText: repairResp.rawText,
      fallbackPhotoID: imageFilename,
    });
  } catch {
    // Repair call threw — keep the original analysis with its
    // validator errors so the engineer can review.
    return { analysis: firstAnalysis, didRepair: false };
  }

  if (repairAnalysis.parseFailed) {
    // Repair returned garbage — keep the original.
    return { analysis: firstAnalysis, didRepair: false };
  }

  // Re-validate the repair response. It MIGHT still have issues
  // (the model failed to follow the instructions) — those land
  // on the new analysis's validationErrors. Either way we
  // accept the repair attempt as "this is what we got."
  repairAnalysis.validationErrors = validateAIResponse({
    analysis: repairAnalysis,
    vocabulary,
  });
  return { analysis: repairAnalysis, didRepair: true };
}

export interface TagPhotoResult {
  analysis: AIPhotoAnalysis;
  /** True when the second-pass repair retry produced the
   *  returned analysis. UI surfaces this so the user knows
   *  the model needed correction. */
  didRepair: boolean;
}
