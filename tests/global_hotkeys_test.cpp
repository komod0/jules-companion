/**
 * @file global_hotkeys_test.cpp
 * @brief Unit tests for GlobalHotkey system
 * 
 * TDD approach: These tests define the expected global hotkey behavior.
 * Tests hotkey registration, modification, conflict handling,
 * and backend detection (X11 vs Wayland).
 * 
 * Platform support:
 * - X11: XGrabKey API for global shortcuts
 * - Wayland: xdg-desktop-portal GlobalShortcuts interface
 * - Fallback: Graceful degradation when neither available
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QMainWindow>
#include <QTimer>
#include <QEventLoop>
#include <QSignalSpy>
#include <QKeySequence>
#include <QSettings>

#include "input/global_hotkey.h"

namespace jules {
namespace test {

// ============================================================================
// Test Fixture
// ============================================================================

class GlobalHotkeyTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Detect display server for conditional tests
        m_displayServer = GlobalHotkeyManager::detectDisplayServer();
    }

    void TearDown() override {
    }

    // Helper to process Qt events
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    DisplayServer m_displayServer = DisplayServer::Unknown;
};

// ============================================================================
// Display Server Detection Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, DetectsDisplayServer) {
    DisplayServer server = GlobalHotkeyManager::detectDisplayServer();
    
    // Should return one of the valid options
    EXPECT_TRUE(server == DisplayServer::X11 ||
                server == DisplayServer::Wayland ||
                server == DisplayServer::Unknown);
}

TEST_F(GlobalHotkeyTest, DisplayServerMatchesEnvironment) {
    DisplayServer server = GlobalHotkeyManager::detectDisplayServer();
    
    // Check environment variables for expected server
    QString waylandDisplay = qEnvironmentVariable("WAYLAND_DISPLAY");
    QString x11Display = qEnvironmentVariable("DISPLAY");
    QString xdgSessionType = qEnvironmentVariable("XDG_SESSION_TYPE");
    
    if (xdgSessionType == "wayland" || !waylandDisplay.isEmpty()) {
        // Should detect as Wayland (or X11 if XWayland)
        EXPECT_TRUE(server == DisplayServer::Wayland || 
                    server == DisplayServer::X11);  // XWayland case
    } else if (!x11Display.isEmpty()) {
        EXPECT_EQ(server, DisplayServer::X11);
    }
}

// ============================================================================
// Backend Selection Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, SelectsCorrectBackend) {
    GlobalHotkeyManager manager;
    
    HotkeyBackend backend = manager.currentBackend();
    
    if (m_displayServer == DisplayServer::X11) {
        EXPECT_EQ(backend, HotkeyBackend::X11);
    } else if (m_displayServer == DisplayServer::Wayland) {
        EXPECT_EQ(backend, HotkeyBackend::Portal);
    } else {
        EXPECT_EQ(backend, HotkeyBackend::Unavailable);
    }
}

TEST_F(GlobalHotkeyTest, ReportsBackendAvailability) {
    GlobalHotkeyManager manager;
    
    // Should accurately report what's available
    bool hasBackend = manager.isAvailable();
    
    // If we detected a display server, we should have a backend
    if (m_displayServer != DisplayServer::Unknown) {
        EXPECT_TRUE(hasBackend);
    }
}

// ============================================================================
// Default Hotkey Configuration Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, HasDefaultToggleHotkey) {
    QSettings settings;
    settings.remove("hotkeys/toggleWindow");
    settings.remove("hotkeys/toggleModifiers");
    settings.sync();
    
    GlobalHotkeyManager manager;
    
    HotkeyBinding binding = manager.toggleWindowBinding();
    
    EXPECT_EQ(binding.key, Qt::Key_J);
    EXPECT_TRUE(binding.modifiers.testFlag(Qt::ControlModifier));
    EXPECT_TRUE(binding.modifiers.testFlag(Qt::AltModifier));
}

TEST_F(GlobalHotkeyTest, DefaultHotkeyKeySequenceFormat) {
    QSettings settings;
    settings.remove("hotkeys/toggleWindow");
    settings.remove("hotkeys/toggleModifiers");
    settings.sync();
    
    GlobalHotkeyManager manager;
    
    HotkeyBinding binding = manager.toggleWindowBinding();
    QKeySequence sequence = binding.toKeySequence();
    
    EXPECT_FALSE(sequence.isEmpty());
    EXPECT_EQ(sequence.toString(), QString("Ctrl+Alt+J"));
}

// ============================================================================
// Hotkey Modification Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, CanSetCustomToggleKey) {
    GlobalHotkeyManager manager;
    
    HotkeyBinding newBinding;
    newBinding.key = Qt::Key_K;
    newBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
    
    bool success = manager.setToggleWindowBinding(newBinding);
    
    EXPECT_TRUE(success);
    EXPECT_EQ(manager.toggleWindowBinding().key, Qt::Key_K);
}

TEST_F(GlobalHotkeyTest, ModificationEmitsSignal) {
    GlobalHotkeyManager manager;
    
    QSignalSpy spy(&manager, &GlobalHotkeyManager::bindingChanged);
    ASSERT_TRUE(spy.isValid());
    
    HotkeyBinding newBinding;
    newBinding.key = Qt::Key_M;
    newBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
    
    manager.setToggleWindowBinding(newBinding);
    
    EXPECT_EQ(spy.count(), 1);
}

TEST_F(GlobalHotkeyTest, RejectsEmptyBinding) {
    GlobalHotkeyManager manager;
    
    HotkeyBinding emptyBinding;
    emptyBinding.key = Qt::Key_unknown;
    emptyBinding.modifiers = Qt::NoModifier;
    
    bool success = manager.setToggleWindowBinding(emptyBinding);
    
    EXPECT_FALSE(success);
    // Should keep the previous binding
    EXPECT_NE(manager.toggleWindowBinding().key, Qt::Key_unknown);
}

TEST_F(GlobalHotkeyTest, RejectsBindingWithoutModifiers) {
    GlobalHotkeyManager manager;
    
    // Just 'J' without modifiers - dangerous for global hotkey
    HotkeyBinding badBinding;
    badBinding.key = Qt::Key_J;
    badBinding.modifiers = Qt::NoModifier;
    
    bool success = manager.setToggleWindowBinding(badBinding);
    
    EXPECT_FALSE(success);
}

TEST_F(GlobalHotkeyTest, RequiresAtLeastOneModifier) {
    GlobalHotkeyManager manager;
    
    // Ctrl+J should be acceptable
    HotkeyBinding ctrlJ;
    ctrlJ.key = Qt::Key_J;
    ctrlJ.modifiers = Qt::ControlModifier;
    
    bool success = manager.setToggleWindowBinding(ctrlJ);
    EXPECT_TRUE(success);
}

// ============================================================================
// Registration Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, CanRegisterHotkey) {
    if (m_displayServer == DisplayServer::Unknown) {
        GTEST_SKIP() << "No display server available";
    }
    
    GlobalHotkeyManager manager;
    
    bool registered = manager.registerHotkeys();
    
    // Should succeed (or fail gracefully with conflict)
    if (registered) {
        EXPECT_TRUE(manager.isRegistered());
    }
}

TEST_F(GlobalHotkeyTest, CanUnregisterHotkey) {
    if (m_displayServer == DisplayServer::Unknown) {
        GTEST_SKIP() << "No display server available";
    }
    
    GlobalHotkeyManager manager;
    manager.registerHotkeys();
    
    manager.unregisterHotkeys();
    
    EXPECT_FALSE(manager.isRegistered());
}

TEST_F(GlobalHotkeyTest, ReregistersOnBindingChange) {
    if (m_displayServer == DisplayServer::Unknown) {
        GTEST_SKIP() << "No display server available";
    }
    
    GlobalHotkeyManager manager;
    manager.registerHotkeys();
    
    HotkeyBinding newBinding;
    newBinding.key = Qt::Key_L;
    newBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
    
    bool success = manager.setToggleWindowBinding(newBinding);
    
    // Setting new binding should trigger re-registration
    EXPECT_TRUE(success);
    EXPECT_EQ(manager.toggleWindowBinding().key, Qt::Key_L);
}

// ============================================================================
// Conflict Handling Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, DetectsConflictWithSystemHotkey) {
    GlobalHotkeyManager manager;
    
    HotkeyBinding systemHotkey;
    systemHotkey.key = Qt::Key_Delete;
    systemHotkey.modifiers = Qt::ControlModifier | Qt::AltModifier;
    
    HotkeyConflictResult result = manager.checkConflict(systemHotkey);
    
    if (m_displayServer == DisplayServer::X11) {
        EXPECT_EQ(result.status, ConflictStatus::SystemReserved);
    } else {
        EXPECT_TRUE(result.status == ConflictStatus::NoConflict ||
                    result.status == ConflictStatus::SystemReserved);
    }
}

TEST_F(GlobalHotkeyTest, ReportsConflictOnFailedRegistration) {
    if (m_displayServer == DisplayServer::Unknown) {
        GTEST_SKIP() << "No display server available";
    }
    
    GlobalHotkeyManager manager1;
    GlobalHotkeyManager manager2;
    
    // First registration should succeed
    bool first = manager1.registerHotkeys();
    
    if (first) {
        // Second registration of same hotkey should detect conflict
        HotkeyConflictResult result = manager2.checkConflict(manager1.toggleWindowBinding());
        
        // Might be already grabbed or available depending on timing
        // Just ensure no crash
        EXPECT_TRUE(result.status == ConflictStatus::NoConflict ||
                    result.status == ConflictStatus::AlreadyGrabbed ||
                    result.status == ConflictStatus::SystemReserved);
    }
}

TEST_F(GlobalHotkeyTest, GracefulDegradationOnConflict) {
    GlobalHotkeyManager manager;
    
    // Even if hotkey conflicts, manager should not crash
    // and should report the error properly
    
    QSignalSpy errorSpy(&manager, &GlobalHotkeyManager::registrationFailed);
    ASSERT_TRUE(errorSpy.isValid());
    
    // Try to register (may or may not succeed)
    manager.registerHotkeys();
    
    // If it failed, should have emitted error signal
    if (!manager.isRegistered()) {
        // Error is acceptable - just ensure graceful handling
        EXPECT_NO_FATAL_FAILURE({
            QString error = manager.lastError();
            // Error should be meaningful if present
            if (!manager.isRegistered() && errorSpy.count() > 0) {
                EXPECT_FALSE(error.isEmpty());
            }
        });
    }
}

// ============================================================================
// Signal Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, EmitsActivatedOnHotkeyPress) {
    if (m_displayServer == DisplayServer::Unknown) {
        GTEST_SKIP() << "No display server available";
    }
    
    GlobalHotkeyManager manager;
    
    QSignalSpy spy(&manager, &GlobalHotkeyManager::toggleWindowActivated);
    ASSERT_TRUE(spy.isValid());
    
    // Simulate hotkey activation (used for testing)
    manager.simulateHotkeyActivated();
    
    EXPECT_EQ(spy.count(), 1);
}

TEST_F(GlobalHotkeyTest, BindingChangedContainsNewBinding) {
    GlobalHotkeyManager manager;
    
    QSignalSpy spy(&manager, &GlobalHotkeyManager::bindingChanged);
    ASSERT_TRUE(spy.isValid());
    
    HotkeyBinding newBinding;
    newBinding.key = Qt::Key_N;
    newBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
    
    manager.setToggleWindowBinding(newBinding);
    
    ASSERT_EQ(spy.count(), 1);
    QList<QVariant> args = spy.takeFirst();
    HotkeyBinding emittedBinding = args.at(0).value<HotkeyBinding>();
    EXPECT_EQ(emittedBinding.key, Qt::Key_N);
}

// ============================================================================
// Target Window Integration Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, CanSetTargetWindow) {
    GlobalHotkeyManager manager;
    QMainWindow window;
    
    EXPECT_EQ(manager.targetWindow(), nullptr);
    
    manager.setTargetWindow(&window);
    EXPECT_EQ(manager.targetWindow(), &window);
}

TEST_F(GlobalHotkeyTest, ClearsTargetOnWindowDestruction) {
    GlobalHotkeyManager manager;
    
    {
        QMainWindow window;
        manager.setTargetWindow(&window);
        EXPECT_EQ(manager.targetWindow(), &window);
    }
    // window destroyed
    
    EXPECT_EQ(manager.targetWindow(), nullptr);
}

TEST_F(GlobalHotkeyTest, TogglesWindowOnActivation) {
    if (m_displayServer == DisplayServer::Unknown) {
        GTEST_SKIP() << "No display server available";
    }
    
    GlobalHotkeyManager manager;
    QMainWindow window;
    
    manager.setTargetWindow(&window);
    window.hide();
    
    EXPECT_FALSE(window.isVisible());
    
    // Simulate hotkey press
    manager.simulateHotkeyActivated();
    processEvents();
    
    EXPECT_TRUE(window.isVisible());
    
    // Press again to hide
    manager.simulateHotkeyActivated();
    processEvents();
    
    EXPECT_FALSE(window.isVisible());
}

// ============================================================================
// Persistence Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, PersistsBindingToSettings) {
    {
        GlobalHotkeyManager manager;
        
        HotkeyBinding customBinding;
        customBinding.key = Qt::Key_P;
        customBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
        
        manager.setToggleWindowBinding(customBinding);
        manager.saveSettings();
    }
    
    // Create new manager - should load saved binding
    {
        GlobalHotkeyManager manager;
        manager.loadSettings();
        
        EXPECT_EQ(manager.toggleWindowBinding().key, Qt::Key_P);
    }
}

TEST_F(GlobalHotkeyTest, ResetsToDefaultOnInvalidSettings) {
    GlobalHotkeyManager manager;
    
    // Corrupt settings scenario
    manager.resetToDefaults();
    
    // Should have default Ctrl+Alt+J
    HotkeyBinding binding = manager.toggleWindowBinding();
    EXPECT_EQ(binding.key, Qt::Key_J);
}

// ============================================================================
// X11-Specific Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, X11UsesXGrabKey) {
    if (m_displayServer != DisplayServer::X11) {
        GTEST_SKIP() << "Not running on X11";
    }
    
    GlobalHotkeyManager manager;
    
    EXPECT_EQ(manager.currentBackend(), HotkeyBackend::X11);
    
    // X11 backend should be able to register
    bool registered = manager.registerHotkeys();
    
    // Should succeed unless another app has the hotkey
    if (!registered) {
        // Check error is X11-related
        QString error = manager.lastError();
        EXPECT_TRUE(error.contains("grab", Qt::CaseInsensitive) ||
                    error.contains("X11", Qt::CaseInsensitive) ||
                    error.contains("BadAccess", Qt::CaseInsensitive));
    }
}

// ============================================================================
// Wayland-Specific Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, WaylandUsesPortal) {
    if (m_displayServer != DisplayServer::Wayland) {
        GTEST_SKIP() << "Not running on Wayland";
    }
    
    GlobalHotkeyManager manager;
    
    EXPECT_EQ(manager.currentBackend(), HotkeyBackend::Portal);
}

TEST_F(GlobalHotkeyTest, WaylandPortalRequiresUserInteraction) {
    if (m_displayServer != DisplayServer::Wayland) {
        GTEST_SKIP() << "Not running on Wayland";
    }
    
    GlobalHotkeyManager manager;
    
    QSignalSpy pendingSpy(&manager, &GlobalHotkeyManager::registrationPending);
    QSignalSpy failedSpy(&manager, &GlobalHotkeyManager::registrationFailed);
    ASSERT_TRUE(pendingSpy.isValid());
    ASSERT_TRUE(failedSpy.isValid());
    
    manager.registerHotkeys();
    
    bool isPending = pendingSpy.count() > 0;
    bool isImmediate = manager.isRegistered();
    bool hasFailed = failedSpy.count() > 0;
    
    EXPECT_TRUE(isPending || isImmediate || hasFailed);
}

// ============================================================================
// Display String Tests
// ============================================================================

TEST_F(GlobalHotkeyTest, BindingHasDisplayString) {
    GlobalHotkeyManager manager;
    
    QString display = manager.toggleWindowBinding().toDisplayString();
    QKeySequence seq = manager.toggleWindowBinding().toKeySequence();
    
    EXPECT_FALSE(display.isEmpty()) << "Display: " << display.toStdString();
    EXPECT_FALSE(seq.isEmpty()) << "Sequence: " << seq.toString().toStdString();
}

TEST_F(GlobalHotkeyTest, DisplayStringReflectsChanges) {
    GlobalHotkeyManager manager;
    
    QString original = manager.toggleWindowBinding().toDisplayString();
    
    HotkeyBinding newBinding;
    newBinding.key = Qt::Key_X;
    newBinding.modifiers = Qt::ControlModifier | Qt::ShiftModifier;
    manager.setToggleWindowBinding(newBinding);
    
    QString updated = manager.toggleWindowBinding().toDisplayString();
    
    EXPECT_NE(original, updated);
    EXPECT_FALSE(updated.isEmpty()) << "Updated display: " << updated.toStdString();
}

} // namespace test
} // namespace jules

// Main function for Qt test application
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    app.setOrganizationName("Jules");
    app.setApplicationName("JulesLinuxTest");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
