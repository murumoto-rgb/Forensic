/**
 * Shared GPS display formatter (Build #6.39.1).
 *
 * Exhibit stamps and report covers must print a hemisphere letter
 * with an absolute value — never a signed easting. Texas
 * 30.26715, −97.74306 is `30.26715° N, 97.74306° W`, not
 * `30.26715° N, -97.74306° E`.
 *
 * Five decimals is ~1 m, matching the previous iOS stamp precision.
 * Zero is N / E. Non-finite values return null so callers can omit
 * the line rather than print "NaN°".
 */

export function formatLatLon(
  latitude: number,
  longitude: number,
  decimals = 5
): string | null {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  const latH = latitude >= 0 ? "N" : "S";
  const lonH = longitude >= 0 ? "E" : "W";
  return `${Math.abs(latitude).toFixed(decimals)}° ${latH}, ${Math.abs(longitude).toFixed(decimals)}° ${lonH}`;
}

export function formatProjectGPS(
  gps: { latitude: number; longitude: number; accuracyFeet?: number | null },
  decimals = 5
): string | null {
  const coords = formatLatLon(gps.latitude, gps.longitude, decimals);
  if (coords == null) return null;
  if (gps.accuracyFeet != null && Number.isFinite(gps.accuracyFeet)) {
    return `${coords} · ±${Math.round(gps.accuracyFeet)} ft`;
  }
  return coords;
}
