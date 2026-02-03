#include "ui/settings_dialog.h"
#include "data/settings_manager.h"
#include "input/global_hotkey.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QGroupBox>
#include <QPushButton>
#include <QDesktopServices>
#include <QUrl>
#include <QMessageBox>
#include <QApplication>
#include <QSettings>

namespace jules {

SettingsDialog::SettingsDialog(QWidget* parent)
    : QDialog(parent)
    , m_apiKeyEdit(nullptr)
    , m_notificationsCheck(nullptr)
    , m_themeCombo(nullptr)
    , m_fontSizeSpin(nullptr)
    , m_toggleHotkeyEdit(nullptr)
    , m_shortcutConflictLabel(nullptr)
    , m_buttonBox(nullptr)
{
    setupUi();
    loadSettings();
}

void SettingsDialog::setupUi() {
    setWindowTitle("Settings");
    setMinimumSize(500, 450);
    
    auto* mainLayout = new QVBoxLayout(this);
    
    auto* tabWidget = new QTabWidget(this);
    tabWidget->addTab(createGeneralTab(), "General");
    tabWidget->addTab(createAppearanceTab(), "Appearance");
    tabWidget->addTab(createShortcutsTab(), "Shortcuts");
    tabWidget->addTab(createAboutTab(), "About");
    
    m_buttonBox = new QDialogButtonBox(
        QDialogButtonBox::Ok | QDialogButtonBox::Cancel | QDialogButtonBox::Apply,
        this);
    
    connect(m_buttonBox, &QDialogButtonBox::accepted, this, &SettingsDialog::accept);
    connect(m_buttonBox, &QDialogButtonBox::rejected, this, &SettingsDialog::reject);
    connect(m_buttonBox->button(QDialogButtonBox::Apply), &QPushButton::clicked,
            this, &SettingsDialog::onApplyClicked);
            
    mainLayout->addWidget(tabWidget);
    mainLayout->addWidget(m_buttonBox);
}

QWidget* SettingsDialog::createGeneralTab() {
    auto* widget = new QWidget(this);
    auto* layout = new QVBoxLayout(widget);
    layout->setSpacing(16);
    
    // API Key Section
    auto* apiKeyGroup = new QGroupBox("Jules API", widget);
    auto* apiKeyLayout = new QFormLayout(apiKeyGroup);
    
    auto* apiKeyContainer = new QWidget(apiKeyGroup);
    auto* apiKeyHBox = new QHBoxLayout(apiKeyContainer);
    apiKeyHBox->setContentsMargins(0, 0, 0, 0);
    
    m_apiKeyEdit = new QLineEdit(apiKeyContainer);
    m_apiKeyEdit->setEchoMode(QLineEdit::Password);
    m_apiKeyEdit->setPlaceholderText("Enter your Jules API key");
    
    auto* getApiKeyBtn = new QPushButton("Get API Key", apiKeyContainer);
    connect(getApiKeyBtn, &QPushButton::clicked, []() {
        QDesktopServices::openUrl(QUrl("https://jules.google.com"));
    });
    
    apiKeyHBox->addWidget(m_apiKeyEdit);
    apiKeyHBox->addWidget(getApiKeyBtn);
    
    apiKeyLayout->addRow("API Key:", apiKeyContainer);
    
    // Notifications Section
    auto* notificationsGroup = new QGroupBox("Notifications", widget);
    auto* notificationsLayout = new QVBoxLayout(notificationsGroup);
    
    m_notificationsCheck = new QCheckBox("Enable desktop notifications", notificationsGroup);
    notificationsLayout->addWidget(m_notificationsCheck);
    
    layout->addWidget(apiKeyGroup);
    layout->addWidget(notificationsGroup);
    layout->addStretch();
    
    return widget;
}

QWidget* SettingsDialog::createAppearanceTab() {
    auto* widget = new QWidget(this);
    auto* layout = new QVBoxLayout(widget);
    
    auto* formLayout = new QFormLayout();
    
    // Theme
    m_themeCombo = new QComboBox(widget);
    m_themeCombo->addItem("System Default", static_cast<int>(Theme::System));
    m_themeCombo->addItem("Light", static_cast<int>(Theme::Light));
    m_themeCombo->addItem("Dark", static_cast<int>(Theme::Dark));
    
    // Font Size
    m_fontSizeSpin = new QSpinBox(widget);
    m_fontSizeSpin->setRange(9, 24);
    m_fontSizeSpin->setValue(12);
    m_fontSizeSpin->setSuffix(" pt");
    
    formLayout->addRow("Theme:", m_themeCombo);
    formLayout->addRow("Font Size:", m_fontSizeSpin);
    
    auto* resetBtn = new QPushButton("Reset to Defaults", widget);
    connect(resetBtn, &QPushButton::clicked, this, &SettingsDialog::onResetAppearance);
    
    layout->addLayout(formLayout);
    layout->addWidget(resetBtn);
    layout->addStretch();
    
    return widget;
}

QWidget* SettingsDialog::createShortcutsTab() {
    auto* widget = new QWidget(this);
    auto* layout = new QVBoxLayout(widget);
    
    auto* formLayout = new QFormLayout();
    
    m_toggleHotkeyEdit = new HotkeyEdit(widget);
    
    formLayout->addRow("Toggle Window:", m_toggleHotkeyEdit);
    
    m_shortcutConflictLabel = new QLabel(widget);
    m_shortcutConflictLabel->setStyleSheet("color: red;");
    m_shortcutConflictLabel->hide();
    
    auto* resetBtn = new QPushButton("Reset to Defaults", widget);
    connect(resetBtn, &QPushButton::clicked, this, &SettingsDialog::onResetShortcuts);
    
    layout->addLayout(formLayout);
    layout->addWidget(m_shortcutConflictLabel);
    layout->addWidget(resetBtn);
    layout->addStretch();
    
    return widget;
}

QWidget* SettingsDialog::createAboutTab() {
    auto* widget = new QWidget(this);
    auto* layout = new QVBoxLayout(widget);
    layout->setAlignment(Qt::AlignHCenter | Qt::AlignTop);
    layout->setSpacing(10);
    
    auto* appName = new QLabel("Jules Companion", widget);
    QFont titleFont = appName->font();
    titleFont.setPointSize(16);
    titleFont.setBold(true);
    appName->setFont(titleFont);
    
    auto* version = new QLabel("Version 1.0.0", widget);
    auto* copyright = new QLabel("© 2024 Google DeepMind", widget);
    
    auto* buttonsLayout = new QHBoxLayout();
    auto* updatesBtn = new QPushButton("Check for Updates", widget);
    auto* feedbackBtn = new QPushButton("Send Feedback", widget);
    
    buttonsLayout->addWidget(updatesBtn);
    buttonsLayout->addWidget(feedbackBtn);
    
    layout->addSpacing(20);
    layout->addWidget(appName);
    layout->addWidget(version);
    layout->addWidget(copyright);
    layout->addSpacing(20);
    layout->addLayout(buttonsLayout);
    layout->addStretch();
    
    return widget;
}

void SettingsDialog::loadSettings() {
    auto& mgr = SettingsManager::instance();
    
    // API Key
    m_apiKeyEdit->setText(mgr.apiKey());
    
    // General
    m_notificationsCheck->setChecked(mgr.notificationsEnabled());
    
    // Appearance - Theme
    Theme theme = mgr.theme();
    int themeIdx = m_themeCombo->findData(static_cast<int>(theme));
    if (themeIdx >= 0) m_themeCombo->setCurrentIndex(themeIdx);
    
    // Appearance - Font size
    m_fontSizeSpin->setValue(mgr.activityFontSize());
    
    // Shortcuts - Load from QSettings for hotkey (GlobalHotkeyManager handles its own persistence)
    QSettings settings;
    int key = settings.value("hotkeys/toggleWindow", Qt::Key_J).toInt();
    int mods = settings.value("hotkeys/toggleModifiers", 
                              static_cast<int>(Qt::ControlModifier | Qt::AltModifier)).toInt();
    
    HotkeyBinding binding;
    binding.key = static_cast<Qt::Key>(key);
    binding.modifiers = static_cast<Qt::KeyboardModifiers>(mods);
    m_toggleHotkeyEdit->setBinding(binding);
}

void SettingsDialog::saveSettings() {
    auto& mgr = SettingsManager::instance();
    
    // API Key
    mgr.setApiKey(m_apiKeyEdit->text());
    
    // General
    mgr.setNotificationsEnabled(m_notificationsCheck->isChecked());
    
    // Appearance
    Theme theme = static_cast<Theme>(m_themeCombo->currentData().toInt());
    mgr.setTheme(theme);
    mgr.setActivityFontSize(m_fontSizeSpin->value());
    
    // Shortcuts - save via QSettings (GlobalHotkeyManager reads from here)
    QSettings settings;
    HotkeyBinding binding = m_toggleHotkeyEdit->binding();
    settings.setValue("hotkeys/toggleWindow", static_cast<int>(binding.key));
    settings.setValue("hotkeys/toggleModifiers", static_cast<int>(binding.modifiers));
    settings.sync();
    
    mgr.sync();
}

void SettingsDialog::accept() {
    saveSettings();
    QDialog::accept();
}

void SettingsDialog::onApplyClicked() {
    saveSettings();
}

void SettingsDialog::onResetAppearance() {
    int systemIdx = m_themeCombo->findData("system");
    if (systemIdx >= 0) m_themeCombo->setCurrentIndex(systemIdx);
    m_fontSizeSpin->setValue(12);
}

void SettingsDialog::onResetShortcuts() {
    HotkeyBinding defaultBinding;
    defaultBinding.key = Qt::Key_J;
    defaultBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
    m_toggleHotkeyEdit->setBinding(defaultBinding);
    m_shortcutConflictLabel->hide();
}

} // namespace jules
