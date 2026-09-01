import { describe, expect, it } from "vitest";
import { applyOptionDefaults } from "../src/exports/options.js";

describe("PDF export option defaults (Build #6.39.1)", () => {
  it("defaults planColorMode to status so old clients keep single-color pins", () => {
    const options = applyOptionDefaults({});
    expect(options.planColorMode).toBe("status");
    expect(options.pinScale).toBe(1);
  });

  it("preserves a requested color mode and pin scale", () => {
    const options = applyOptionDefaults({
      planColorMode: "bucket",
      pinScale: 2,
    });
    expect(options.planColorMode).toBe("bucket");
    expect(options.pinScale).toBe(2);
  });
});
