/**
 * Web re-export of the shared pin-color helper (Build #6.39.1).
 * Implementation lives in `@forensic/shared` so the server PDF
 * exporter uses the same function as the plan canvas.
 */
export {
  DEFAULT_PIN_COLOR,
  NEUTRAL_PIN_COLOR,
  pinColorFor,
  type PlanColorMode,
} from "@forensic/shared";
