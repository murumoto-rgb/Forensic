import CoreLocation
import Foundation
import Observation

enum LocationError: Error {
    case denied
    case servicesDisabled
    case noLocation
}

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Prompt for permission if not yet asked, otherwise return the current status.
    func requestPermission() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            authContinuation = cont
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One-shot location request. Throws if permission is denied or the request fails.
    func currentLocation() async throws -> CLLocation {
        switch authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            _ = await requestPermission()
            if authorizationStatus == .denied || authorizationStatus == .restricted {
                throw LocationError.denied
            }
        default:
            break
        }
        return try await withCheckedThrowingContinuation { cont in
            locationContinuation = cont
            manager.requestLocation()
        }
    }

    /// Reverse geocode to a compact address. Returns nil on failure.
    func reverseGeocode(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        return Self.formatAddress(from: placemark)
    }

    static func formatAddress(from p: CLPlacemark) -> String? {
        var parts: [String] = []
        if let num = p.subThoroughfare, let road = p.thoroughfare {
            parts.append("\(num) \(road)")
        } else if let road = p.thoroughfare {
            parts.append(road)
        }
        if let city = p.locality ?? p.subLocality {
            parts.append(city)
        }
        if let state = p.administrativeArea, let postal = p.postalCode {
            parts.append("\(state) \(postal)")
        } else if let state = p.administrativeArea {
            parts.append(state)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if let cont = authContinuation {
            authContinuation = nil
            cont.resume(returning: manager.authorizationStatus)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, let cont = locationContinuation else { return }
        locationContinuation = nil
        cont.resume(returning: loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let cont = locationContinuation else { return }
        locationContinuation = nil
        cont.resume(throwing: error)
    }
}
