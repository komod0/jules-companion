#pragma once

#include <QDialog>
#include <QTabWidget>
#include <QLineEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QSpinBox>
#include <QLabel>
#include <QDialogButtonBox>
#include <QPushButton>
#include <QListWidget>
#include <QTimer>
#include "ui/hotkey_edit.h"

namespace jules {
class SessionRepository;
class BoidsWidget;
}

namespace jules {

class SettingsDialog : public QDialog {
    Q_OBJECT

public:
    explicit SettingsDialog(SessionRepository* repository = nullptr, QWidget* parent = nullptr);
    ~SettingsDialog() override = default;

public slots:
    void accept() override;
    void onApplyClicked();
    void onResetAppearance();
    void onResetShortcuts();
    void onClearCacheClicked();
    void onAddRepositoryFolder();
    void onRemoveRepositoryFolder();

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
    QCheckBox* m_launchAtLoginCheck;
    
    // Appearance Tab Widgets
    QComboBox* m_themeCombo;
    QSpinBox* m_fontSizeSpin;
    
    // Storage Widgets
    QLabel* m_cacheCountLabel;
    QPushButton* m_clearCacheBtn;
    SessionRepository* m_repository;
    
    // Repository Folders Widgets
    QListWidget* m_repoFoldersList;
    QPushButton* m_addFolderBtn;
    QPushButton* m_removeFolderBtn;
    
    // Shortcuts Tab Widgets
    HotkeyEdit* m_toggleHotkeyEdit;
    QLabel* m_shortcutConflictLabel;
    
    // Dialog Buttons
    QDialogButtonBox* m_buttonBox;
    
    // About Tab Widgets
    BoidsWidget* m_boidsWidget = nullptr;
    QTimer* m_boidsTimer = nullptr;
};

} // namespace jules
