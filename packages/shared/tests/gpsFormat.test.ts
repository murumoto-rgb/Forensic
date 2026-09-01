import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { formatLatLon, formatProjectGPS } from "../src/gpsFormat.ts";

describe("formatLatLon", () => {
  it("prints Austin west longitude as W, never a negative easting", () => {
    assert.equal(
      formatLatLon(30.26715, -97.74306),
      "30.26715° N, 97.74306° W"
    );
  });

  it("prints southern / eastern hemispheres", () => {
    assert.equal(formatLatLon(-33.8688, 151.2093), "33.86880° S, 151.20930° E");
  });

  it("treats zero as N / E", () => {
    assert.equal(formatLatLon(0, 0), "0.00000° N, 0.00000° E");
  });

  it("returns null for non-finite values", () => {
    assert.equal(formatLatLon(Number.NaN, -97), null);
    assert.equal(formatLatLon(30, Number.POSITIVE_INFINITY), null);
  });
});

describe("formatProjectGPS", () => {
  it("appends rounded accuracy when present", () => {
    assert.equal(
      formatProjectGPS({
        latitude: 30.26715,
        longitude: -97.74306,
        accuracyFeet: 12.4,
      }),
      "30.26715° N, 97.74306° W · ±12 ft"
    );
  });

  it("omits accuracy when null", () => {
    assert.equal(
      formatProjectGPS({ latitude: 30, longitude: -97, accuracyFeet: null }),
      "30.00000° N, 97.00000° W"
    );
  });
});
