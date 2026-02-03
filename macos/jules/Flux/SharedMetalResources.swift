import MetalKit

// MARK: - Shared Metal Resources Manager

/// Manages Metal resources with lazy loading and release capability for memory optimization.
/// Resources are created on-demand when session windows open and can be released when
/// the app transitions to menubar-only mode.
///
/// Previous implementation used global constants that were created at app launch and never released.
/// This manager allows significant memory savings (~50-100MB) when running in menubar-only mode.
@MainActor
final class SharedMetalResourcesManager {
    static let shared = SharedMetalResourcesManager()

    // MARK: - Private Storage

    private var _device: MTLDevice?
    private var _commandQueue: MTLCommandQueue?
    private var _fontAtlasManager: FontAtlasManager?

    /// Track whether resources have been explicitly released
    private var isReleased: Bool = false

    private init() {}

    // MARK: - Public API

    /// Shared Metal device - created lazily on first access.
    /// Returns nil if Metal is not available on this system.
    var device: MTLDevice? {
        if isReleased { return nil }
        if _device == nil {
            _device = MTLCreateSystemDefaultDevice()
            if _device != nil {
                print("[Metal] Created shared Metal device")
            }
        }
        return _device
    }

    /// Shared Metal command queue - created lazily on first access.
    /// Returns nil if Metal device is not available.
    var commandQueue: MTLCommandQueue? {
        if isReleased { return nil }
        if _commandQueue == nil, let device = device {
            _commandQueue = device.makeCommandQueue()
            if _commandQueue != nil {
                print("[Metal] Created shared command queue")
            }
        }
        return _commandQueue
    }

    /// Shared FontAtlasManager - created lazily on first access.
    /// Returns nil if Metal device is not available.
    var fontAtlasManager: FontAtlasManager? {
        if isReleased { return nil }
        if _fontAtlasManager == nil, let device = device {
            _fontAtlasManager = FontAtlasManager(device: device)
            print("[Metal] Created shared FontAtlasManager")
        }
        return _fontAtlasManager
    }

    /// Check if Metal resources are currently loaded
    var hasLoadedResources: Bool {
        return _device != nil || _commandQueue != nil || _fontAtlasManager != nil
    }

    /// Release all Metal resources to reduce memory footprint.
    /// Call this when transitioning to menubar-only mode (all windows closed).
    /// Resources will be recreated lazily when needed again.
    func releaseResources() {
        guard hasLoadedResources else { return }

        print("[Metal] Releasing shared Metal resources to reduce memory")

        // Release in reverse order of dependency
        _fontAtlasManager = nil
        _commandQueue = nil
        _device = nil
        isReleased = true

        print("[Metal] Shared Metal resources released")
    }

    /// Prepare resources for use (called when a window opens).
    /// This clears the released flag so resources can be created lazily.
    func prepareForUse() {
        if isReleased {
            print("[Metal] Preparing Metal resources for use")
            isReleased = false
        }
    }
}

// MARK: - Convenience Accessors

/// Shared Metal device - use SharedMetalResourcesManager.shared.device for explicit lifecycle control.
/// This computed property provides backward compatibility with existing code.
@MainActor
var fluxSharedMetalDevice: MTLDevice? {
    return SharedMetalResourcesManager.shared.device
}

/// Shared Metal command queue - use SharedMetalResourcesManager.shared.commandQueue for explicit lifecycle control.
/// This computed property provides backward compatibility with existing code.
@MainActor
var fluxSharedCommandQueue: MTLCommandQueue? {
    return SharedMetalResourcesManager.shared.commandQueue
}

/// Shared FontAtlasManager - use SharedMetalResourcesManager.shared.fontAtlasManager for explicit lifecycle control.
/// This computed property provides backward compatibility with existing code.
@MainActor
var fluxSharedFontAtlasManager: FontAtlasManager? {
    return SharedMetalResourcesManager.shared.fontAtlasManager
}
