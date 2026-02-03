#pragma once

#include <QDialog>
#include <QTabWidget>
#include <QLineEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QSpinBox>
#include <QLabel>
#include <QDialogButtonBox>
#include "ui/hotkey_edit.h"

namespace jules {

class SettingsDialog : public QDialog {
    Q_OBJECT

public:
    explicit SettingsDialog(QWidget* parent = nullptr);
    ~SettingsDialog() override = default;

public slots:
    void accept() override;
    void onApplyClicked();
    void onResetAppearance();
    void onResetShortcuts();

private:
    void setupUi();
    QWidget* createGeneralTab();
    QWidget* createAppearanceTab();
    QWidget* createShortcutsTab();
    QWidget* createAboutTab();
    
    void loadSettings();
    void saveSettings();

    // General Tab Widgets
    QLineEdit* m_apiKeyEdit;
    QCheckBox* m_notificationsCheck;
    
    // Appearance Tab Widgets
    QComboBox* m_themeCombo;
    QSpinBox* m_fontSizeSpin;
    
    // Shortcuts Tab Widgets
    HotkeyEdit* m_toggleHotkeyEdit;
    QLabel* m_shortcutConflictLabel;
    
    // Dialog Buttons
    QDialogButtonBox* m_buttonBox;
};

} // namespace jules
