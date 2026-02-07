#include "app/app_controller.h"

#include <QApplication>
#include <QStandardPaths>
#include <QDir>
#include <QDesktopServices>
#include <QUrl>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QMessageBox>
#include <QShortcut>
#include <QDebug>

#include "ui/main_window.h"
#include "ui/system_tray.h"
#include "ui/tray_popup_widget.h"
#include "ui/session_list_widget.h"
#include "ui/session_detail_widget.h"
#include "ui/settings_dialog.h"
#include "ui/new_session_dialog.h"
#include "ui/flash_message_widget.h"
#include "ui/feedback_dialog.h"
#include "ui/command_palette.h"
#include "data/settings_manager.h"
#include "data/database.h"
#include "data/session_repository.h"
#include "data/network_monitor.h"
#include "data/offline_sync_manager.h"
#include "data/diffs_database.h"
#include "data/filename_autocomplete_manager.h"
#include "rendering/shared_syntax_cache.h"
#include "rendering/diff_precomputation_service.h"
#include "api/jules_api_client.h"
#include "input/global_hotkey.h"

namespace jules {

AppController::AppController(QObject* parent)
    : QObject(parent)
{
}

AppController::~AppController() = default;

void AppController::initialize()
{
    createServices();
    createUi();
    connectSignals();
    setupKeyboardShortcuts();
    loadInitialData();

    m_window->restoreWindowState();
    m_window->show();

    // Show API key setup prompt if not configured
    if (SettingsManager::instance().apiKey().isEmpty()) {
        QTimer::singleShot(500, [this]() {
            m_window->showFlashMessage(
                "No API key configured. Open Settings or set JULES_API_KEY env var.",
                FlashMessageType::Warning, 5000);
        });
    }
}

void AppController::shutdown()
{
    m_networkMonitor->stopMonitoring();
    m_hotkeyManager->unregisterHotkeys();
    m_hotkeyManager->saveSettings();
    m_window->saveWindowState();
}

void AppController::createServices()
{
    auto& settings = SettingsManager::instance();

    // Setup data directory
    QString dataPath = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataPath);

    // Initialize database
    m_database = std::make_unique<Database>(dataPath);
    if (!m_database->initialize()) {
        QMessageBox::critical(nullptr, "Database Error",
            "Failed to initialize database. The application will exit.");
        QApplication::exit(1);
        return;
    }

    // Create session repository
    m_repository = std::make_unique<SessionRepository>(m_database.get());

    // Initialize diffs database (separate from main DB)
    m_diffsDb = std::make_unique<DiffsDatabase>(dataPath);
    if (!m_diffsDb->initialize()) {
        qWarning() << "Failed to initialize diffs database (non-fatal)";
    }

    // Network monitoring
    m_networkMonitor = std::make_unique<NetworkMonitor>();
    m_networkMonitor->startMonitoring();

    // Create network manager and API client
    m_networkManager = std::make_unique<QNetworkAccessManager>();
    m_apiClient = std::make_unique<JulesApiClient>(m_networkManager.get());

    // Offline sync manager
    m_offlineSyncManager = std::make_unique<OfflineSyncManager>(m_database.get());
    m_offlineSyncManager->setApiClient(m_apiClient.get());
    m_offlineSyncManager->setNetworkMonitor(m_networkMonitor.get());

    // Shared syntax cache (5K entries)
    m_syntaxCache = std::make_unique<SharedSyntaxCache>(5000);

    // Diff precomputation service
    m_diffPrecompService = std::make_unique<DiffPrecomputationService>();

    // Filename autocomplete manager
    m_autocompleteManager = std::make_unique<FilenameAutocompleteManager>();
    m_autocompleteManager->setRepositoryFolders(settings.repositoryFolders());

    // syntaxCache: lifecycle managed here, consumed by DiffRenderer internally via singleton
    (void)m_syntaxCache;
    // diffsDb: standalone diffs storage, available for future DiffPrecomputationService persistence
    (void)m_diffsDb;

    // Load API key from settings
    QString apiKey = settings.apiKey();
    qDebug() << "API Key configured:" << !apiKey.isEmpty();
    if (!apiKey.isEmpty()) {
        m_apiClient->setApiKey(apiKey);
    }
}

void AppController::createUi()
{
    auto& settings = SettingsManager::instance();

    // Create main window
    m_window = std::make_unique<MainWindow>();
    m_window->setTheme(settings.theme());

    // Add Settings button to toolbar
    QAction* toolbarSettingsAction = m_window->mainToolbar()->addAction(QString::fromUtf8("\xe2\x9a\x99 Settings"));
    connect(toolbarSettingsAction, &QAction::triggered, [this]() {
        SettingsDialog dialog(m_repository.get(), m_window.get());
        dialog.exec();
    });

    // Create session list widget (for sidebar)
    m_sessionListWidget = new SessionListWidget(m_repository.get());
    qDebug() << "Created SessionListWidget";
    m_window->setSidebarContent(m_sessionListWidget);
    qDebug() << "Set sidebar content";

    // Create session detail widget (for main content)
    m_sessionDetailWidget = new SessionDetailWidget();
    qDebug() << "Created SessionDetailWidget";
    m_window->setMainContent(m_sessionDetailWidget);
    qDebug() << "Set main content";

    // Create system tray
    m_systemTray = std::make_unique<SystemTray>();
    m_systemTray->setTargetWindow(m_window.get());
    if (m_systemTray->isAvailable()) {
        m_systemTray->show();
    }

    // Create tray popup widget (like macOS menu bar popup)
    m_trayPopup = new TrayPopupWidget(m_repository.get());

    // Create global hotkey manager
    m_hotkeyManager = std::make_unique<GlobalHotkeyManager>();
    m_hotkeyManager->setTargetWindow(m_window.get());
    m_hotkeyManager->loadSettings();
    m_hotkeyManager->registerHotkeys();

    // Create command palette
    m_commandPalette = new CommandPalette(m_window.get());
}

void AppController::connectSignals()
{
    auto& settings = SettingsManager::instance();

    // ========================================================================
    // Settings changes
    // ========================================================================
    connect(&settings, &SettingsManager::themeChanged,
            m_window.get(), &MainWindow::setTheme);

    // Theme -> system tray icon adaptation
    connect(m_window.get(), &MainWindow::themeChanged,
            [this](Theme) {
        bool isDark = (m_window->effectiveTheme() == Theme::Dark);
        m_systemTray->updateTheme(isDark);
    });
    // Set initial tray theme
    m_systemTray->updateTheme(m_window->effectiveTheme() == Theme::Dark);

    connect(&settings, &SettingsManager::apiKeyChanged, [this]() {
        auto& s = SettingsManager::instance();
        m_apiClient->setApiKey(s.apiKey());
        // Refetch sessions when API key changes
        if (!s.apiKey().isEmpty()) {
            m_apiClient->getSessions();
        }
    });

    // Settings -> autocomplete manager
    connect(&settings, &SettingsManager::repositoryFoldersChanged,
            [this]() {
        m_autocompleteManager->setRepositoryFolders(
            SettingsManager::instance().repositoryFolders());
    });

    // ========================================================================
    // Menu bar actions
    // ========================================================================
    connect(m_window.get(), &MainWindow::settingsRequested, [this]() {
        SettingsDialog dialog(m_repository.get(), m_window.get());
        dialog.exec();
    });

    connect(m_window.get(), &MainWindow::quitRequested, []() {
        QApplication::quit();
    });

    // ========================================================================
    // System tray actions
    // ========================================================================
    connect(m_systemTray.get(), &SystemTray::settingsRequested, [this]() {
        SettingsDialog dialog(m_repository.get(), m_window.get());
        dialog.exec();
    });

    connect(m_systemTray.get(), &SystemTray::quitRequested, []() {
        QApplication::quit();
    });

    // ========================================================================
    // Tray popup signals
    // ========================================================================
    connect(m_systemTray.get(), &SystemTray::popupRequested,
            m_trayPopup, &TrayPopupWidget::showNearPosition);

    connect(m_trayPopup, &TrayPopupWidget::sessionSelected,
            [this](const QString& sessionId) {
        auto session = m_repository->getSession(sessionId);
        if (session) {
            m_sessionDetailWidget->setSession(*session);
            m_apiClient->getActivities(sessionId);
            m_window->show();
            m_window->raise();
            m_window->activateWindow();
        }
    });

    connect(m_trayPopup, &TrayPopupWidget::settingsRequested,
            [this]() {
        SettingsDialog dialog(m_repository.get(), m_window.get());
        dialog.exec();
    });

    connect(m_trayPopup, &TrayPopupWidget::quitRequested, []() {
        QApplication::quit();
    });

    // ========================================================================
    // Session list -> session detail
    // ========================================================================
    connect(m_sessionListWidget, &SessionListWidget::sessionSelected,
            [this](const QString& sessionId) {
        qDebug() << "[main] sessionSelected:" << sessionId.left(8);
        auto session = m_repository->getSession(sessionId);
        if (session) {
            m_sessionDetailWidget->setSession(*session);
            qDebug() << "[main] Calling getActivities for" << sessionId.left(8);
            m_apiClient->getActivities(sessionId);
        } else {
            m_sessionDetailWidget->clear();
        }
    });

    // New session from tray popup (quick create with first source)
    connect(m_trayPopup, &TrayPopupWidget::newSessionRequested,
            [this](const QString& prompt) {
        if (!m_cachedSources.isEmpty()) {
            const Source& source = m_cachedSources.first();
            m_apiClient->createSession(source, QString(), prompt);
        }
    });

    // Create new session
    connect(m_sessionListWidget, &SessionListWidget::createNewRequested,
            [this]() {
        if (m_cachedSources.isEmpty()) {
            QMessageBox::information(m_window.get(), "No Repositories",
                "No repositories available. Please configure your API key in Settings.");
            return;
        }

        NewSessionDialog dialog(m_cachedSources, m_window.get());
        dialog.setAutocompleteManager(m_autocompleteManager.get());
        connect(&dialog, &NewSessionDialog::sessionRequested,
                [this](const Source& source, const QString& branch, const QString& prompt) {
            m_apiClient->createSession(source, branch, prompt);
        });
        dialog.exec();
    });

    // Session list context menu -> open in browser
    connect(m_sessionListWidget, &SessionListWidget::openInBrowserRequested,
            [](const QString& sessionId) {
        QString url = QString("https://jules.google.com/session/%1").arg(sessionId);
        QDesktopServices::openUrl(QUrl(url));
    });

    // Session detail -> open URLs
    connect(m_sessionDetailWidget, &SessionDetailWidget::openUrlRequested,
            [](const QString& url) {
        QDesktopServices::openUrl(QUrl(url));
    });

    // ========================================================================
    // API client -> session repository
    // ========================================================================
    connect(m_apiClient.get(), &JulesApiClient::sessionsReceived,
            [this](const QList<Session>& sessions, const QString&) {
        m_repository->saveSessions(sessions);

        // Extract sources from sessions for new session dialog
        m_cachedSources.clear();
        for (const auto& session : sessions) {
            if (session.sourceContext && !session.sourceContext->source.isEmpty()) {
                Source source;
                source.name = session.sourceContext->source;
                source.id = session.sourceContext->source;

                bool found = false;
                for (const auto& existing : m_cachedSources) {
                    if (existing.id == source.id) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    m_cachedSources.append(source);
                }
            }
        }

        m_sessionListWidget->refresh();

        // Update command palette sessions
        QList<QPair<QString,QString>> paletteSessions;
        for (const auto& s : sessions) {
            QString name = s.title.value_or(s.prompt.left(60));
            paletteSessions.append({s.id, name});
        }
        m_commandPalette->setSessions(paletteSessions);
    });

    connect(m_apiClient.get(), &JulesApiClient::sessionReceived,
            [this](const Session& session) {
        m_repository->saveSession(session);
        m_sessionListWidget->refresh();

        // Update detail if this is the currently displayed session
        if (!m_sessionDetailWidget->isEmpty() &&
            m_sessionDetailWidget->displayedText().contains(session.id)) {
            m_sessionDetailWidget->setSession(session);
        }
    });

    connect(m_apiClient.get(), &JulesApiClient::activitiesReceived,
            [this](const QString& sessionId, const QList<Activity>& activities) {
        qDebug() << "[main] activitiesReceived for session" << sessionId.left(8) << "with" << activities.size() << "activities";

        auto session = m_repository->getSession(sessionId);
        if (session) {
            Session updated = *session;
            updated.activities = activities;
            updated.updateCachedDiffData();
            updated.activitiesFetched = true;

            qDebug() << "[main] After updateCachedDiffData: hasDiffs=" << updated.cachedLatestDiffs.has_value()
                     << "diffCount=" << (updated.cachedLatestDiffs.has_value() ? updated.cachedLatestDiffs->size() : 0);

            m_repository->saveSession(updated);
            m_sessionDetailWidget->setSession(updated);
        }
    });

    connect(m_apiClient.get(), &JulesApiClient::activitiesUnchanged,
            [this](const QString& sessionId) {
        qDebug() << "[main] Activities unchanged for session" << sessionId.left(8) << "(hash match, skipping update)";
        auto session = m_repository->getSession(sessionId);
        if (session) {
            Session updated = *session;
            updated.activitiesFetched = true;
            m_repository->saveSession(updated);
            m_sessionDetailWidget->setSession(updated);
        }
    });

    // Activities -> diff precomputation service
    connect(m_apiClient.get(), &JulesApiClient::activitiesReceived,
            [this](const QString& sessionId, const QList<Activity>&) {
        auto session = m_repository->getSession(sessionId);
        if (session && session->cachedLatestDiffs.has_value()) {
            m_diffPrecompService->precomputeAll(sessionId, *session->cachedLatestDiffs);
        }
    });

    // Precomputation complete -> update detail widget if showing this session
    connect(m_diffPrecompService.get(), &DiffPrecomputationService::precomputationComplete,
            [this](const QString& sessionId) {
        auto session = m_repository->getSession(sessionId);
        if (session) {
            m_sessionDetailWidget->setSession(*session);
        }
    });

    // Sessions unchanged (hash match optimization)
    connect(m_apiClient.get(), &JulesApiClient::sessionsUnchanged, []() {
        qDebug() << "[main] Sessions unchanged (hash match, skipping update)";
    });

    connect(m_apiClient.get(), &JulesApiClient::sessionCreated,
            [this](const Session& session) {
        m_repository->saveSession(session);
        m_sessionListWidget->refresh();
        m_sessionDetailWidget->setSession(session);
        m_window->showFlashMessage("Session created successfully", FlashMessageType::Success);
    });

    connect(m_apiClient.get(), &JulesApiClient::errorOccurred,
            [this](const ApiError& error) {
        QString message;
        switch (error.type) {
            case ApiErrorType::Unauthorized:
                message = "Authentication failed. Please check your API key in Settings.";
                break;
            case ApiErrorType::NetworkError:
                message = "Network error: " + error.message;
                break;
            case ApiErrorType::RateLimited:
                message = "Rate limited. Please wait before making more requests.";
                break;
            default:
                message = error.message.isEmpty() ? "An error occurred" : error.message;
                break;
        }

        m_window->showFlashMessage(message, FlashMessageType::Error);
        m_systemTray->setState(TrayState::Error);

        QTimer::singleShot(5000, [this]() {
            m_systemTray->setState(TrayState::Idle);
        });
    });

    // ========================================================================
    // Global hotkey
    // ========================================================================
    connect(m_hotkeyManager.get(), &GlobalHotkeyManager::toggleWindowActivated, [this]() {
        if (m_window->isVisible() && m_window->isActiveWindow()) {
            m_window->hide();
        } else {
            m_window->show();
            m_window->raise();
            m_window->activateWindow();
        }
    });

    // ========================================================================
    // Tray state tracking
    // ========================================================================
    connect(m_repository.get(), &SessionRepository::sessionsReloaded,
            this, &AppController::updateTrayState);
    connect(m_repository.get(), &SessionRepository::sessionChanged,
            this, &AppController::updateTrayState);

    // ========================================================================
    // Network monitor -> UI
    // ========================================================================
    connect(m_networkMonitor.get(), &NetworkMonitor::connectivityChanged,
            m_window.get(), &MainWindow::setNetworkOnline);

    // ========================================================================
    // Command palette actions
    // ========================================================================
    connect(m_commandPalette, &CommandPalette::newSessionRequested,
            m_sessionListWidget, &SessionListWidget::requestCreateNew);

    connect(m_commandPalette, &CommandPalette::settingsRequested, [this]() {
        SettingsDialog dialog(m_repository.get(), m_window.get());
        dialog.exec();
    });

    connect(m_commandPalette, &CommandPalette::refreshRequested, [this]() {
        if (!SettingsManager::instance().apiKey().isEmpty()) {
            m_apiClient->getSessions();
        }
    });

    connect(m_commandPalette, &CommandPalette::actionTriggered,
            [this](const QString& actionId, const QString& sessionId) {
        if (actionId == "goto_session" && !sessionId.isEmpty()) {
            auto session = m_repository->getSession(sessionId);
            if (session) {
                m_sessionDetailWidget->setSession(*session);
                m_apiClient->getActivities(sessionId);
            }
        }
    });
}

void AppController::setupKeyboardShortcuts()
{
    auto& settings = SettingsManager::instance();

    // Ctrl+N -> new session
    m_shortcutNew = new QShortcut(QKeySequence::New, m_window.get());
    connect(m_shortcutNew, &QShortcut::activated,
            m_sessionListWidget, &SessionListWidget::requestCreateNew);

    // Ctrl+R -> refresh sessions from API
    m_shortcutRefresh = new QShortcut(QKeySequence::Refresh, m_window.get());
    connect(m_shortcutRefresh, &QShortcut::activated, [this]() {
        if (!SettingsManager::instance().apiKey().isEmpty()) {
            m_apiClient->getSessions();
        }
    });

    // Ctrl+F -> focus search field
    m_shortcutFind = new QShortcut(QKeySequence::Find, m_window.get());
    connect(m_shortcutFind, &QShortcut::activated, [this]() {
        if (auto* searchField = m_sessionListWidget->searchField()) {
            searchField->setFocus();
            searchField->selectAll();
        }
    });

    // Ctrl+K -> command palette
    m_shortcutCommandPalette = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key_K), m_window.get());
    connect(m_shortcutCommandPalette, &QShortcut::activated, [this]() {
        if (m_commandPalette->isVisible()) {
            m_commandPalette->hidePalette();
        } else {
            m_commandPalette->showPalette();
        }
    });
}

void AppController::loadInitialData()
{
    auto& settings = SettingsManager::instance();

    // Load sessions from local database first
    m_sessionListWidget->refresh();

    // If we have an API key, fetch fresh data from server
    if (!settings.apiKey().isEmpty()) {
        m_apiClient->getSessions();
    }

    // Start polling for session updates
    m_sessionListWidget->setPollingIntervalMs(30000); // 30 seconds
    m_sessionListWidget->startPolling();

    // Periodic refresh from API (every 60 seconds)
    m_refreshTimer = new QTimer(this);
    connect(m_refreshTimer, &QTimer::timeout, [this]() {
        if (!SettingsManager::instance().apiKey().isEmpty()) {
            m_apiClient->getSessions();
        }
    });
    m_refreshTimer->start(60000);
}

void AppController::updateTrayState()
{
    auto activeSessions = m_repository->getActiveSessions();

    if (activeSessions.isEmpty()) {
        m_systemTray->setState(TrayState::Idle);
        return;
    }

    // Determine highest-priority state across all active sessions
    TrayState bestState = TrayState::Idle;

    for (const auto& session : activeSessions) {
        TrayState sessionState = TrayState::Idle;

        switch (session.state) {
            case SessionState::Queued:
                sessionState = TrayState::Queued;
                break;
            case SessionState::Planning:
                sessionState = TrayState::Planning;
                break;
            case SessionState::InProgress:
                sessionState = TrayState::Running;
                break;
            case SessionState::AwaitingPlanApproval:
            case SessionState::AwaitingUserFeedback:
                sessionState = TrayState::NeedsAttention;
                break;
            case SessionState::Paused:
                sessionState = TrayState::Paused;
                break;
            case SessionState::Failed:
                sessionState = TrayState::Failed;
                break;
            case SessionState::Completed:
            case SessionState::CompletedUnknown:
            case SessionState::Unspecified:
            default:
                sessionState = TrayState::Idle;
                break;
        }

        // Priority: NeedsAttention > Running > Planning > Queued > Failed > Paused > Idle
        if (sessionState == TrayState::NeedsAttention) {
            bestState = TrayState::NeedsAttention;
            break;  // Highest priority, stop searching
        } else if (sessionState == TrayState::Running && bestState != TrayState::NeedsAttention) {
            bestState = TrayState::Running;
        } else if ((sessionState == TrayState::Planning || sessionState == TrayState::Queued) &&
                   bestState != TrayState::NeedsAttention && bestState != TrayState::Running) {
            bestState = sessionState;
        } else if (sessionState == TrayState::Failed &&
                   bestState != TrayState::NeedsAttention && bestState != TrayState::Running &&
                   bestState != TrayState::Planning && bestState != TrayState::Queued) {
            bestState = TrayState::Failed;
        } else if (sessionState == TrayState::Paused && bestState == TrayState::Idle) {
            bestState = TrayState::Paused;
        }
    }

    m_systemTray->setState(bestState);
}

} // namespace jules
