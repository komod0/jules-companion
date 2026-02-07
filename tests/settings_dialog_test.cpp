#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QTabWidget>
#include <QLineEdit>
#include <QComboBox>
#include <QSpinBox>
#include <QDialogButtonBox>
#include <QCheckBox>
#include <QListWidget>

#include "ui/settings_dialog.h"

namespace jules {
namespace test {

class SettingsDialogTest : public ::testing::Test {
protected:
};

TEST_F(SettingsDialogTest, CanConstruct) {
    SettingsDialog dialog(nullptr, nullptr);
    SUCCEED();
}

TEST_F(SettingsDialogTest, HasWindowTitle) {
    SettingsDialog dialog(nullptr, nullptr);
    EXPECT_FALSE(dialog.windowTitle().isEmpty());
}

TEST_F(SettingsDialogTest, HasTabs) {
    SettingsDialog dialog(nullptr, nullptr);
    auto* tabWidget = dialog.findChild<QTabWidget*>();
    ASSERT_NE(tabWidget, nullptr);
    EXPECT_GE(tabWidget->count(), 3);
}

TEST_F(SettingsDialogTest, HasApiKeyField) {
    SettingsDialog dialog(nullptr, nullptr);
    auto* lineEdit = dialog.findChild<QLineEdit*>();
    EXPECT_NE(lineEdit, nullptr);
}

TEST_F(SettingsDialogTest, HasThemeCombo) {
    SettingsDialog dialog(nullptr, nullptr);
    auto* combo = dialog.findChild<QComboBox*>();
    ASSERT_NE(combo, nullptr);
    EXPECT_GE(combo->count(), 2);
}

TEST_F(SettingsDialogTest, HasFontSizeSpin) {
    SettingsDialog dialog(nullptr, nullptr);
    auto* spin = dialog.findChild<QSpinBox*>();
    ASSERT_NE(spin, nullptr);
    EXPECT_GE(spin->minimum(), 6);
    EXPECT_LE(spin->maximum(), 48);
}

TEST_F(SettingsDialogTest, AcceptDoesNotCrash) {
    SettingsDialog dialog(nullptr, nullptr);
    EXPECT_NO_THROW(dialog.accept());
}

TEST_F(SettingsDialogTest, ResetAppearanceDoesNotCrash) {
    SettingsDialog dialog(nullptr, nullptr);
    EXPECT_NO_THROW(dialog.onResetAppearance());
}

TEST_F(SettingsDialogTest, ResetShortcutsDoesNotCrash) {
    SettingsDialog dialog(nullptr, nullptr);
    EXPECT_NO_THROW(dialog.onResetShortcuts());
}

TEST_F(SettingsDialogTest, HasButtonBox) {
    SettingsDialog dialog(nullptr, nullptr);
    auto* buttonBox = dialog.findChild<QDialogButtonBox*>();
    ASSERT_NE(buttonBox, nullptr);
    EXPECT_NE(buttonBox->button(QDialogButtonBox::Ok), nullptr);
    EXPECT_NE(buttonBox->button(QDialogButtonBox::Cancel), nullptr);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
