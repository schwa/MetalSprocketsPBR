#if os(visionOS)
import ARKit
import Metal
import os
import Synchronization

/// Lighting from the room around the viewer: ARKit's environment probes, turned into a ``PBREnvironment`` as they
/// update. Run ``run()`` in a task while an immersive space is open and read ``environment`` each frame.
///
/// The probe sits at the headset, so it suits models near the viewer. ARKit gives no texture in a poorly lit room;
/// ``environment`` then keeps the last one (or nil).
public final class PBRRoomLighting: Sendable {
    public enum Status: Sendable, Equatable {
        case idle
        case starting
        /// The device has no environment light estimation.
        case unsupported
        /// The person declined an authorization the provider needs.
        case notAuthorized
        /// Running, but ARKit has not given a texture yet (or the room is too dark).
        case waitingForLight
        case running
        case failed(String)
    }

    /// Updates closer together than this are skipped: each rebuilds and prefilters an environment on the GPU.
    public let minimumInterval: Duration
    /// Multiplies the probe's brightness.
    public let scale: Float

    private let state = Mutex<(environment: PBREnvironment?, status: Status, isRunning: Bool)>((nil, .idle, false))
    private static let logger = Logger(subsystem: "MetalSprocketsPBR", category: "RoomLighting")

    public init(minimumInterval: Duration = .seconds(1), scale: Float = 1) {
        self.minimumInterval = minimumInterval
        self.scale = scale
    }

    /// The latest room environment, or nil before the first one.
    public var environment: PBREnvironment? {
        state.withLock { $0.environment }
    }

    public var status: Status {
        state.withLock { $0.status }
    }

    private func setStatus(_ status: Status) {
        state.withLock { $0.status = status }
    }

    /// Runs the ARKit session until the task is cancelled, asking for any authorization the provider needs. Returns at
    /// once if another `run()` is still going.
    public func run() async {
        let alreadyRunning = state.withLock { state in
            defer { state.isRunning = true }
            return state.isRunning
        }
        guard !alreadyRunning else {
            Self.logger.info("Room lighting is already running; ignoring a second run()")
            return
        }
        defer { state.withLock { $0.isRunning = false } }
        setStatus(.starting)
        guard EnvironmentLightEstimationProvider.isSupported else {
            Self.logger.info("Environment light estimation is not supported on this device")
            setStatus(.unsupported)
            return
        }
        let session = ARKitSession()
        let needed = EnvironmentLightEstimationProvider.requiredAuthorizations
        Self.logger.info("Environment light estimation needs authorizations: \(String(describing: needed), privacy: .public)")
        if !needed.isEmpty {
            let results = await session.requestAuthorization(for: needed)
            guard results.values.allSatisfy({ $0 == .allowed }) else {
                Self.logger.info("Environment light estimation not authorized: \(String(describing: results), privacy: .public)")
                setStatus(.notAuthorized)
                return
            }
        }
        let provider = EnvironmentLightEstimationProvider()
        do {
            try await session.run([provider])
        } catch {
            Self.logger.error("Environment light estimation failed to start: \(error, privacy: .public)")
            setStatus(.failed("\(error)"))
            return
        }
        defer { session.stop() }
        setStatus(.waitingForLight)
        // Stopping the session ends `anchorUpdates`, so cancellation does not wait for another update.
        await withTaskCancellationHandler {
            await receiveUpdates(from: provider)
        } onCancel: {
            session.stop()
        }
        setStatus(.idle)
    }

    private func receiveUpdates(from provider: EnvironmentLightEstimationProvider) async {
        var lastBuild: ContinuousClock.Instant?
        var hasLoggedTexture = false
        for await update in provider.anchorUpdates {
            if Task.isCancelled {
                break
            }
            // The texture lives only as long as the anchor, so it is converted here, before the next update.
            guard let texture = update.anchor.environmentTexture else {
                if environment == nil {
                    setStatus(.waitingForLight)
                }
                continue
            }
            if let lastBuild, ContinuousClock.now - lastBuild < minimumInterval {
                continue
            }
            if !hasLoggedTexture {
                hasLoggedTexture = true
                Self.logger.info("Environment probe: \(texture.width)x\(texture.height) \(String(describing: texture.pixelFormat), privacy: .public), \(texture.mipmapLevelCount) mips, cameraScaleReference \(update.anchor.cameraScaleReference)")
            }
            let start = ContinuousClock.now
            do {
                let environment = try PBREnvironment(cube: texture, colorMatrix: PBREnvironment.displayP3ToLinearSRGB, scale: scale)
                state.withLock {
                    $0.environment = environment
                    $0.status = .running
                }
                lastBuild = start
                Self.logger.debug("Room environment rebuilt in \(ContinuousClock.now - start, privacy: .public)")
            } catch {
                Self.logger.error("Room environment failed: \(error, privacy: .public)")
                setStatus(.failed("\(error)"))
            }
        }
    }
}
#endif
