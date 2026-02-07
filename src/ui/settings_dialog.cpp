#include "ui/settings_dialog.h"
#include "ui/app_colors.h"
#include "data/settings_manager.h"
#include "data/session_repository.h"
#include "input/global_hotkey.h"
#include "rendering/boids_widget.h"

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
#include <QFileDialog>
#include <QStackedLayout>

namespace jules {

SettingsDialog::SettingsDialog(SessionRepository* repository, QWidget* parent)
    : QDialog(parent)
    , m_apiKeyEdit(nullptr)
    , m_notificationsCheck(nullptr)
    , m_launchAtLoginCheck(nullptr)
    , m_themeCombo(nullptr)
    , m_fontSizeSpin(nullptr)
    , m_cacheCountLabel(nullptr)
    , m_clearCacheBtn(nullptr)
    , m_repository(repository)
    , m_repoFoldersList(nullptr)
    , m_addFolderBtn(nullptr)
    , m_removeFolderBtn(nullptr)
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

    connect(tabWidget, &QTabWidget::currentChanged, this, [this](int index) {
        constexpr int aboutIdx = 3;
        if (index == aboutIdx) {
            if (m_boidsTimer) m_boidsTimer->start(16);
        } else {
            if (m_boidsTimer) m_boidsTimer->stop();
        }
    });

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
    
    // Startup Section
    auto* startupGroup = new QGroupBox("Startup", widget);
    auto* startupLayout = new QVBoxLayout(startupGroup);
    
    m_launchAtLoginCheck = new QCheckBox("Launch at login", startupGroup);
    startupLayout->addWidget(m_launchAtLoginCheck);
    
    // Repository Folders Section
    auto* repoGroup = new QGroupBox("Repository Folders", widget);
    auto* repoLayout = new QVBoxLayout(repoGroup);
    
    auto* repoLabel = new QLabel("Local folders for code repositories. Used for merge operations and filename autocomplete.", repoGroup);
    repoLabel->setWordWrap(true);
    bool isDark = palette().window().color().lightness() < 128;
    repoLabel->setStyleSheet(QString("color: %1; font-size: 11px;")
        .arg(AppColors::textSecondary(isDark).name()));
    
    m_repoFoldersList = new QListWidget(repoGroup);
    m_repoFoldersList->setMaximumHeight(100);
    m_repoFoldersList->setSelectionMode(QAbstractItemView::SingleSelection);
    
    auto* repoButtonsLayout = new QHBoxLayout();
    m_addFolderBtn = new QPushButton("Add Folder...", repoGroup);
    m_removeFolderBtn = new QPushButton("Remove", repoGroup);
    m_removeFolderBtn->setEnabled(false);
    
    connect(m_addFolderBtn, &QPushButton::clicked, this, &SettingsDialog::onAddRepositoryFolder);
    connect(m_removeFolderBtn, &QPushButton::clicked, this, &SettingsDialog::onRemoveRepositoryFolder);
    connect(m_repoFoldersList, &QListWidget::itemSelectionChanged, [this]() {
        m_removeFolderBtn->setEnabled(m_repoFoldersList->currentItem() != nullptr);
    });
    
    repoButtonsLayout->addWidget(m_addFolderBtn);
    repoButtonsLayout->addWidget(m_removeFolderBtn);
    repoButtonsLayout->addStretch();
    
    repoLayout->addWidget(repoLabel);
    repoLayout->addWidget(m_repoFoldersList);
    repoLayout->addLayout(repoButtonsLayout);
    
    layout->addWidget(apiKeyGroup);
    layout->addWidget(notificationsGroup);
    layout->addWidget(startupGroup);
    layout->addWidget(repoGroup);
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
    m_themeCombo->addItem("Solarized Dark", static_cast<int>(Theme::SolarizedDark));
    m_themeCombo->addItem("Dracula", static_cast<int>(Theme::Dracula));
    m_themeCombo->addItem("Nord", static_cast<int>(Theme::Nord));
    m_themeCombo->addItem("Monokai", static_cast<int>(Theme::Monokai));
    m_themeCombo->addItem("One Dark", static_cast<int>(Theme::OneDark));
    
    // Font Size
    m_fontSizeSpin = new QSpinBox(widget);
    m_fontSizeSpin->setRange(9, 24);
    m_fontSizeSpin->setValue(12);
    m_fontSizeSpin->setSuffix(" pt");
    
    formLayout->addRow("Theme:", m_themeCombo);
    formLayout->addRow("Font Size:", m_fontSizeSpin);
    
    auto* resetBtn = new QPushButton("Reset to Defaults", widget);
    connect(resetBtn, &QPushButton::clicked, this, &SettingsDialog::onResetAppearance);
    
    // Storage Section
    auto* storageGroup = new QGroupBox("Storage", widget);
    auto* storageLayout = new QHBoxLayout(storageGroup);
    
    m_cacheCountLabel = new QLabel("Cached sessions: 0", storageGroup);
    m_clearCacheBtn = new QPushButton("Clear Cache", storageGroup);
    connect(m_clearCacheBtn, &QPushButton::clicked, this, &SettingsDialog::onClearCacheClicked);
    
    storageLayout->addWidget(m_cacheCountLabel);
    storageLayout->addStretch();
    storageLayout->addWidget(m_clearCacheBtn);
    
    layout->addLayout(formLayout);
    layout->addWidget(resetBtn);
    layout->addWidget(storageGroup);
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
    bool isDark = palette().window().color().lightness() < 128;
    m_shortcutConflictLabel->setStyleSheet(
        QString("color: %1;").arg(AppColors::destructive(isDark).name()));
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
    
    // Create a stacked layout to layer boids behind content
    auto* stackedLayout = new QStackedLayout(widget);
    stackedLayout->setStackingMode(QStackedLayout::StackAll);
    
    // Background: Boids animation widget
    m_boidsWidget = new BoidsWidget(widget);
    m_boidsWidget->setParticleCount(150);
    m_boidsWidget->setParticleColor({0.541f, 0.459f, 1.0f, 0.7f}); // Purple fish
    m_boidsWidget->setBackgroundColor({0.08f, 0.08f, 0.12f, 1.0f}); // Dark background
    m_boidsWidget->setRenderMode(BoidsRenderMode::Full);
    m_boidsWidget->setAttribute(Qt::WA_TransparentForMouseEvents);
    
    // Animation timer for boids
    m_boidsTimer = new QTimer(this);
    connect(m_boidsTimer, &QTimer::timeout, [this]() {
        if (m_boidsWidget && m_boidsWidget->isVisible()) {
            m_boidsWidget->update(1.0f / 60.0f);
            m_boidsWidget->QOpenGLWidget::update();
        }
    });
    // Timer starts stopped; activated when About tab is selected (see setupUi)
    
    // Foreground: Content overlay
    auto* contentWidget = new QWidget(widget);
    contentWidget->setAttribute(Qt::WA_TranslucentBackground);
    auto* layout = new QVBoxLayout(contentWidget);
    layout->setAlignment(Qt::AlignHCenter | Qt::AlignTop);
    layout->setSpacing(10);
    
    auto* appName = new QLabel("Jules Companion", contentWidget);
    QFont titleFont = appName->font();
    titleFont.setPointSize(18);
    titleFont.setBold(true);
    appName->setFont(titleFont);
    appName->setStyleSheet("color: white; background: transparent;");
    appName->setAlignment(Qt::AlignCenter);
    
    auto* version = new QLabel("Version 1.0.0", contentWidget);
    version->setStyleSheet("color: rgba(255, 255, 255, 0.8); background: transparent;");
    version->setAlignment(Qt::AlignCenter);
    
    auto* copyright = new QLabel("© 2026 Google DeepMind", contentWidget);
    copyright->setStyleSheet("color: rgba(255, 255, 255, 0.6); background: transparent;");
    copyright->setAlignment(Qt::AlignCenter);
    
    auto* buttonsWidget = new QWidget(contentWidget);
    auto* buttonsLayout = new QHBoxLayout(buttonsWidget);
    buttonsLayout->setAlignment(Qt::AlignCenter);
    
    auto* updatesBtn = new QPushButton("Check for Updates", buttonsWidget);
    auto* feedbackBtn = new QPushButton("Send Feedback", buttonsWidget);
    
    QString buttonStyle = R"(
        QPushButton {
            background-color: rgba(138, 117, 255, 0.8);
            color: white;
            border: none;
            border-radius: 6px;
            padding: 8px 16px;
            font-weight: 500;
        }
        QPushButton:hover {
            background-color: rgba(138, 117, 255, 1.0);
        }
        QPushButton:pressed {
            background-color: rgba(118, 97, 235, 1.0);
        }
    )";
    updatesBtn->setStyleSheet(buttonStyle);
    feedbackBtn->setStyleSheet(buttonStyle);
    
    buttonsLayout->addWidget(updatesBtn);
    buttonsLayout->addWidget(feedbackBtn);
    
    auto* logoLabel = new QLabel(contentWidget);
    QPixmap logo(":/icons/jules-128.png");
    logoLabel->setPixmap(logo.scaled(80, 80, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    logoLabel->setAlignment(Qt::AlignCenter);
    logoLabel->setStyleSheet("background: transparent;");

    auto* description = new QLabel("Desktop companion for Google Jules AI", contentWidget);
    description->setStyleSheet("color: rgba(255, 255, 255, 0.7); background: transparent; font-size: 12px;");
    description->setAlignment(Qt::AlignCenter);

    layout->addSpacing(40);
    layout->addWidget(logoLabel);
    layout->addWidget(appName);
    layout->addWidget(version);
    layout->addWidget(description);
    layout->addWidget(copyright);
    layout->addSpacing(30);
    layout->addWidget(buttonsWidget);
    layout->addStretch();
    
    // Add widgets to stacked layout (order matters: first added is on bottom)
    stackedLayout->addWidget(m_boidsWidget);
    stackedLayout->addWidget(contentWidget);
    
    return widget;
}

void SettingsDialog::loadSettings() {
    auto& mgr = SettingsManager::instance();
    
    // API Key
    m_apiKeyEdit->setText(mgr.apiKey());
    
    // General
    m_notificationsCheck->setChecked(mgr.notificationsEnabled());
    m_launchAtLoginCheck->setChecked(mgr.launchAtLoginEnabled());
    
    // Update cache count
    if (m_repository) {
        int count = m_repository->cachedSessionCount();
        m_cacheCountLabel->setText(QString("Cached sessions: %1").arg(count));
    }
    
    // Repository Folders
    m_repoFoldersList->clear();
    m_repoFoldersList->addItems(mgr.repositoryFolders());
    
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
    mgr.setLaunchAtLoginEnabled(m_launchAtLoginCheck->isChecked());
    
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
    int systemIdx = m_themeCombo->findData(static_cast<int>(Theme::System));
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

void SettingsDialog::onClearCacheClicked() {
    if (!m_repository) {
        return;
    }
    
    int count = m_repository->cachedSessionCount();
    if (count == 0) {
        QMessageBox::information(this, "Cache Empty", "There are no cached sessions to clear.");
        return;
    }
    
    auto reply = QMessageBox::question(
        this,
        "Clear Cache",
        QString("Are you sure you want to clear %1 cached session(s)?\n\n"
                "This will remove all locally stored session data. "
                "Your sessions on the server will not be affected.").arg(count),
        QMessageBox::Yes | QMessageBox::No,
        QMessageBox::No
    );
    
    if (reply == QMessageBox::Yes) {
        if (m_repository->clearAllCachedData()) {
            m_cacheCountLabel->setText("Cached sessions: 0");
            QMessageBox::information(this, "Cache Cleared", "All cached sessions have been cleared.");
        } else {
            QMessageBox::warning(this, "Error", "Failed to clear cache. Please try again.");
        }
    }
}

void SettingsDialog::onAddRepositoryFolder() {
    QString folder = QFileDialog::getExistingDirectory(
        this,
        "Select Repository Folder",
        QDir::homePath(),
        QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks
    );
    
    if (!folder.isEmpty()) {
        // Check if folder already exists in list
        for (int i = 0; i < m_repoFoldersList->count(); ++i) {
            if (m_repoFoldersList->item(i)->text() == folder) {
                QMessageBox::information(this, "Folder Exists", "This folder is already in the list.");
                return;
            }
        }
        
        // Add to list and save
        m_repoFoldersList->addItem(folder);
        SettingsManager::instance().addRepositoryFolder(folder);
    }
}

void SettingsDialog::onRemoveRepositoryFolder() {
    QListWidgetItem* item = m_repoFoldersList->currentItem();
    if (item) {
        QString folder = item->text();
        delete m_repoFoldersList->takeItem(m_repoFoldersList->row(item));
        SettingsManager::instance().removeRepositoryFolder(folder);
        m_removeFolderBtn->setEnabled(false);
    }
}

} // namespace jules
