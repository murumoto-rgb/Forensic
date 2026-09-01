import Foundation
import Observation

/// Advisory edit-lock presence for the project workspace
/// (Build #6.21.1 — the iOS half of Phase 5's checkout/edit lock;
/// server shipped #5.59.1, web #5.60.1/#5.120.1).
///
/// Design decisions, deliberate and different from web:
///
/// * **iOS never blocks editing on the lock.** Field capture must
///   work offline and must never wait on a lock round-trip; the
///   server-side 3-way merge (#5.117.1–#5.119.1) already makes
///   concurrent edits lossless. The lock is presence signaling.
/// * **Acquire-while-open.** When the workspace opens, iOS takes the
///   lock if it's free (or already this account's) so web reviewers
///   see "being edited on iPhone" and don't fight the phone.
///   Heartbeats every 90 s keep it alive while the workspace stays
///   open; closing the workspace releases it.
/// * **Held by someone else → banner only.** The workspace shows an
///   amber advisory strip with the holder's email; editing stays
///   enabled and the copy says edits will merge.
/// * **Backgrounding:** the heartbeat task freezes with the app; if
///   the app stays backgrounded past the 10-minute TTL the server
///   treats the lock as lapsed (a web user can take it, optionally
///   triggering the #5.61.1 takeover email). On foreground return
///   the next tick re-acquires if it's free. No
///   `willResignActive` release — a brief app switch in the field
///   shouldn't hand the lock away.
///
/// Errors are silent by design (advisory feature; the field engineer
/// shouldn't get network-error toasts about a presence signal).
@Observable
@MainActor
final class ProjectLockController {
    enum Status: Equatable {
        /// Not yet determined / signed out / network unavailable.
        case unknown
        /// This account holds the lock (from this device or any
        /// other client — same-account web sessions count).
        case heldByMe
        /// A different account holds a live lock.
        case heldByOther(email: String, client: String)
    }

    private(set) var status: Status = .unknown

    private let api: APIClient
    private let projectID: UUID
    private var loopTask: Task<Void, Never>?

    /// Poll/heartbeat cadence. Matches web's 90 s heartbeat; the
    /// 10-minute TTL gives ~6 missed beats of slack on flaky field
    /// connections before the lock lapses.
    private static let tickInterval: Duration = .seconds(90)

    init(api: APIClient, projectID: UUID) {
        self.api = api
        self.projectID = projectID
    }

    /// Begin the get→acquire→heartbeat loop. Idempotent.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Stop the loop and release the lock if this device holds it.
    /// Called when the workspace closes.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        let held = (status == .heldByMe)
        status = .unknown
        guard held else { return }
        let api = self.api
        let id = projectID
        // Fire-and-forget; the TTL is the backstop if this fails.
        Task { try? await api.releaseLock(projectId: id) }
    }

    private func tick() async {
        // While holding: heartbeat. A 409 means the lock was force-
        // released or taken over — fall through to re-read.
        if status == .heldByMe {
            do {
                _ = try await api.heartbeatLock(projectId: projectID)
                return
            } catch APIClient.APIError.http(status: 409, _, _) {
                status = .unknown
            } catch {
                // Network blip — keep the held state and retry next
                // tick; the TTL window absorbs several misses.
                return
            }
        }

        do {
            let resp = try await api.getLock(projectId: projectID)
            if let lock = resp.lock {
                if resp.heldByYou == "session" {
                    // Same account holds it (possibly a web tab).
                    // Heartbeating from here keeps it alive without
                    // stealing the row from the web session.
                    status = .heldByMe
                    return
                }
                status = .heldByOther(email: lock.userEmail,
                                      client: lock.client)
                return
            }
            // Free → take it so web sees the phone editing.
            _ = try await api.acquireLock(projectId: projectID)
            status = .heldByMe
        } catch APIClient.APIError.http(status: 409, _, _) {
            // Lost the acquire race; surface whoever won.
            if let resp = try? await api.getLock(projectId: projectID),
               let lock = resp.lock, resp.heldByYou != "session" {
                status = .heldByOther(email: lock.userEmail,
                                      client: lock.client)
            }
        } catch {
            // notAuthenticated / transport — advisory only; leave
            // status as-is and retry next tick.
        }
    }
}
