import { describe, expect, it } from "vitest";
import { probeImageDimensions } from "../src/exports/imageProbe.js";

describe("bounded PDF image dimension probe", () => {
  it("rejects unsupported or malformed formats without scanning indefinitely", () => {
    expect(() => probeImageDimensions(Buffer.from("icns-jxl-garbage"))).toThrow(/JPEG or PNG/);
    expect(() => probeImageDimensions(Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0, 2]))).toThrow(/JPEG or PNG/);
  });
  it("probes PNG dimensions from the bounded header", () => {
    const bytes = Buffer.alloc(33);
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]).copy(bytes);
    bytes.writeUInt32BE(13, 8);
    bytes.write("IHDR", 12, "ascii");
    bytes.writeUInt32BE(1200, 16);
    bytes.writeUInt32BE(800, 20);
    expect(probeImageDimensions(bytes)).toEqual({ width: 1200, height: 800, type: "png" });
  });
});
