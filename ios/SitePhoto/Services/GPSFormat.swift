import Foundation

/// Shared GPS display formatter (Build #6.39.1).
///
/// Exhibit stamps and report covers must print a hemisphere letter
/// with an absolute value — never a signed easting. Texas
/// 30.26715, −97.74306 is `30.26715° N, 97.74306° W`, not
/// `30.26715° N, -97.74306° E`.
///
/// Five decimals is ~1 m, matching the previous stamp precision.
/// Zero is N / E.
enum GPSFormat {
    static func coordinateString(latitude: Double,
                                 longitude: Double) -> String? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let latH = latitude >= 0 ? "N" : "S"
        let lonH = longitude >= 0 ? "E" : "W"
        return String(format: "%.5f° %@, %.5f° %@",
                      abs(latitude), latH,
                      abs(longitude), lonH)
    }

    static func coordinateString(_ gps: ProjectGPS) -> String? {
        coordinateString(latitude: gps.latitude, longitude: gps.longitude)
    }
}
