export function probeImageDimensions(bytes: Buffer): { width: number; height: number; type: "jpeg" | "png" } {
  if (bytes.length >= 33 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])) && bytes.readUInt32BE(8) === 13 && bytes.toString("ascii", 12, 16) === "IHDR") {
    const width = bytes.readUInt32BE(16); const height = bytes.readUInt32BE(20);
    if (width > 0 && height > 0) return { width, height, type: "png" };
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < bytes.length && offset < 1_048_576) {
      if (bytes[offset] !== 0xff) { offset++; continue; }
      const marker = bytes[offset + 1]!; offset += 2;
      if (marker === 0xd8 || marker === 0xd9) continue;
      if (offset + 2 > bytes.length) break;
      const length = bytes.readUInt16BE(offset); if (length < 2 || offset + length > bytes.length) break;
      if ((marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc5 && marker <= 0xc7) || (marker >= 0xc9 && marker <= 0xcb) || (marker >= 0xcd && marker <= 0xcf)) {
        if (length >= 7) { const height = bytes.readUInt16BE(offset + 3); const width = bytes.readUInt16BE(offset + 5); if (width && height) return { width, height, type: "jpeg" }; }
      }
      offset += length;
    }
  }
  throw new Error("Unsupported or malformed image; expected JPEG or PNG");
}
