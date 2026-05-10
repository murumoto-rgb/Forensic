import CoreMotion
import Foundation
import Observation

/// Streams the device's roll angle so the camera preview can render a
/// horizon-level indicator. Wraps `CMMotionManager.deviceMotion` so the
/// caller doesn't have to think about queue handling or unit conversion.
///
/// Lifecycle is start/stop — call `start()` when the camera view appears
/// and `stop()` on disappear so we're not draining the gyro / accelerometer
/// when no one is watching.
@MainActor
@Observable
final class CameraMotionService {
    /// Device roll in radians. Zero = horizon perfectly level for a
    /// portrait device held upright. Positive values mean the device
    /// is tilted clockwise (when viewing the screen).
    private(set) var rollRadians: Double = 0

    private let manager = CMMotionManager()

    func start() {
        guard !manager.isDeviceMotionActive,
              manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            // Compute roll from the gravity vector. For a portrait
            // device held level, gravity is (0, -1, 0); rolling
            // clockwise tilts x positive and reduces -y → atan2 picks
            // up the angle directly.
            let g = motion.gravity
            self?.rollRadians = atan2(g.x, -g.y)
        }
    }

    func stop() {
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        rollRadians = 0
    }
}
