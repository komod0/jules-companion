#include <gtest/gtest.h>
#include "ui/hotkey_edit.h"
#include <QApplication>

// Note: On Fedora containers, Qt widget teardown can segfault.
// All tests pass but the crash happens in global teardown.
// This is a known Qt/X11 issue in containerized environments.

class HotkeyEditTest : public ::testing::Test {
protected:
    static void SetUpTestSuite() {
        if (!QApplication::instance()) {
            static int argc = 0;
            static char** argv = nullptr;
            static QApplication app(argc, argv);
        }
    }
    
    static void TearDownTestSuite() {
        // Process any pending events to help with clean shutdown
        if (QApplication::instance()) {
            QApplication::processEvents();
        }
    }
};

TEST_F(HotkeyEditTest, InitialStateShowsDefaultBinding) {
    // HotkeyBinding defaults to Ctrl+Alt+J
    jules::HotkeyEdit edit;
    // Qt uses "Control" in display strings on some platforms
    QString text = edit.text();
    EXPECT_TRUE(text.contains("J")) << "Expected binding with J key, got: " << text.toStdString();
    EXPECT_TRUE(text.contains("Alt") || text.contains("Meta")) << "Expected Alt modifier, got: " << text.toStdString();
}

TEST_F(HotkeyEditTest, SetBindingUpdatesDisplay) {
    jules::HotkeyEdit edit;
    jules::HotkeyBinding binding{Qt::Key_K, Qt::ControlModifier | Qt::ShiftModifier};
    edit.setBinding(binding);
    QString text = edit.text();
    EXPECT_TRUE(text.contains("K")) << "Expected binding with K key, got: " << text.toStdString();
    // Verify binding was set correctly (locale-agnostic)
    EXPECT_EQ(edit.binding().key, Qt::Key_K);
    EXPECT_TRUE(edit.binding().modifiers & Qt::ShiftModifier);
}

TEST_F(HotkeyEditTest, ClearResetsBinding) {
    jules::HotkeyEdit edit;
    edit.setBinding({Qt::Key_K, Qt::ControlModifier});
    edit.clear();
    // After clear, binding key should be reset to default (Qt::Key_J from HotkeyBinding default constructor)
    // But clear() sets m_binding = HotkeyBinding{} which uses defaults
    EXPECT_EQ(edit.binding().key, Qt::Key_J);
}

TEST_F(HotkeyEditTest, BindingChangeEmitsSignal) {
    jules::HotkeyEdit edit;
    bool signalReceived = false;
    QObject::connect(&edit, &jules::HotkeyEdit::bindingChanged, [&signalReceived](const jules::HotkeyBinding&) {
        signalReceived = true;
    });
    edit.setBinding({Qt::Key_X, Qt::AltModifier});
    EXPECT_TRUE(signalReceived);
}
