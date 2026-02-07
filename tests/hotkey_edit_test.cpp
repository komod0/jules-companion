#include <gtest/gtest.h>
#include "ui/hotkey_edit.h"
#include <QApplication>
#include <QSignalSpy>

// Note: On Fedora containers, Qt widget teardown can segfault.
// All tests pass but the crash happens in global teardown.
// This is a known Qt/X11 issue in containerized environments.

class HotkeyEditTest : public ::testing::Test {
protected:
    // No static QApplication - it's created in main() below
};

// Custom main to control QApplication lifetime properly
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    int result = RUN_ALL_TESTS();
    // Let app clean up properly before returning
    QApplication::processEvents();
    return result;
}

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

TEST_F(HotkeyEditTest, SetCtrlShiftAltBinding) {
    jules::HotkeyEdit edit;
    jules::HotkeyBinding binding{Qt::Key_P, Qt::ControlModifier | Qt::ShiftModifier | Qt::AltModifier};
    edit.setBinding(binding);
    auto result = edit.binding();
    EXPECT_EQ(result.key, Qt::Key_P);
    EXPECT_TRUE(result.modifiers & Qt::ControlModifier);
    EXPECT_TRUE(result.modifiers & Qt::ShiftModifier);
    EXPECT_TRUE(result.modifiers & Qt::AltModifier);
}

TEST_F(HotkeyEditTest, SetFunctionKeyBinding) {
    jules::HotkeyEdit edit;
    jules::HotkeyBinding binding{Qt::Key_F5, Qt::ControlModifier};
    edit.setBinding(binding);
    EXPECT_EQ(edit.binding().key, Qt::Key_F5);
}

TEST_F(HotkeyEditTest, BindingDisplayContainsKeyName) {
    jules::HotkeyEdit edit;
    jules::HotkeyBinding binding{Qt::Key_K, Qt::ControlModifier};
    edit.setBinding(binding);
    QString text = edit.text();
    EXPECT_TRUE(text.contains("K")) << "Expected display to contain 'K', got: " << text.toStdString();
}

TEST_F(HotkeyEditTest, SetSameBindingDoesNotEmitTwice) {
    jules::HotkeyEdit edit;
    jules::HotkeyBinding binding{Qt::Key_M, Qt::ControlModifier | Qt::ShiftModifier};
    edit.setBinding(binding);

    QSignalSpy spy(&edit, &jules::HotkeyEdit::bindingChanged);
    ASSERT_TRUE(spy.isValid());

    // Setting the same binding again should not emit
    edit.setBinding(binding);
    EXPECT_EQ(spy.count(), 0);
}

TEST_F(HotkeyEditTest, ClearEmitsBindingChanged) {
    jules::HotkeyEdit edit;
    edit.setBinding({Qt::Key_N, Qt::AltModifier});

    QSignalSpy spy(&edit, &jules::HotkeyEdit::bindingChanged);
    ASSERT_TRUE(spy.isValid());

    edit.clear();
    EXPECT_GE(spy.count(), 1);
}

TEST_F(HotkeyEditTest, RapidSetBindingCalls) {
    jules::HotkeyEdit edit;
    const Qt::Key keys[] = {
        Qt::Key_A, Qt::Key_B, Qt::Key_C, Qt::Key_D, Qt::Key_E,
        Qt::Key_F, Qt::Key_G, Qt::Key_H, Qt::Key_I, Qt::Key_Z
    };
    for (auto k : keys) {
        edit.setBinding({k, Qt::ControlModifier});
    }
    EXPECT_EQ(edit.binding().key, Qt::Key_Z);
}

TEST_F(HotkeyEditTest, MultipleEditsAreIndependent) {
    jules::HotkeyEdit edit1;
    jules::HotkeyEdit edit2;
    edit1.setBinding({Qt::Key_A, Qt::ControlModifier});
    edit2.setBinding({Qt::Key_B, Qt::ShiftModifier});
    EXPECT_EQ(edit1.binding().key, Qt::Key_A);
    EXPECT_EQ(edit2.binding().key, Qt::Key_B);
    EXPECT_TRUE(edit1.binding().modifiers & Qt::ControlModifier);
    EXPECT_TRUE(edit2.binding().modifiers & Qt::ShiftModifier);
}

TEST_F(HotkeyEditTest, BindingKeyAccessor) {
    jules::HotkeyEdit edit;
    edit.setBinding({Qt::Key_W, Qt::AltModifier});
    EXPECT_EQ(edit.binding().key, Qt::Key_W);
    edit.setBinding({Qt::Key_Q, Qt::ControlModifier});
    EXPECT_EQ(edit.binding().key, Qt::Key_Q);
}
