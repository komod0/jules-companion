#include <gtest/gtest.h>
#include "ui/hotkey_edit.h"
#include <QApplication>

TEST(HotkeyEditTest, InitialStateShowsNone) {
    int argc = 0;
    char** argv = nullptr;
    QApplication app(argc, argv);
    jules::HotkeyEdit edit;
    EXPECT_EQ(edit.text().toStdString(), "None");
}

TEST(HotkeyEditTest, SetBindingUpdatesDisplay) {
    int argc = 0;
    char** argv = nullptr;
    QApplication app(argc, argv);
    jules::HotkeyEdit edit;
    jules::HotkeyBinding binding{Qt::Key_J, Qt::ControlModifier | Qt::AltModifier};
    edit.setBinding(binding);
    EXPECT_EQ(edit.text().toStdString(), "Ctrl+Alt+J");
}

TEST(HotkeyEditTest, ClearResetsToNone) {
    int argc = 0;
    char** argv = nullptr;
    QApplication app(argc, argv);
    jules::HotkeyEdit edit;
    edit.setBinding({Qt::Key_K, Qt::ControlModifier});
    edit.clear();
    EXPECT_EQ(edit.binding().key, Qt::Key_unknown);
}
