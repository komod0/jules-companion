#include <QApplication>
#include <QGuiApplication>
#include <QStyleHints>
#include <QStandardPaths>
#include <QDir>
#include <QDesktopServices>
#include <QUrl>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QMessageBox>
#include <QDebug>

#include "ui/main_window.h"
#include "ui/system_tray.h"
#include "ui/session_list_widget.h"
#include "ui/session_detail_widget.h"
#include "ui/settings_dialog.h"
#include "ui/new_session_dialog.h"
#include "ui/flash_message_widget.h"
#include "data/settings_manager.h"
#include "data/database.h"
#include "data/session_repository.h"
#include "api/jules_api_client.h"
#include "input/global_hotkey.h"

using namespace jules;

int main(int argc, char *argv[])
{
    QGuiApplication::setDesktopFileName("jules-linux");
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinux");
    QCoreApplication::setApplicationName("Jules");

    // Initialize settings manager
    auto& settings = SettingsManager::instance();
    
    // Setup data directory
    QString dataPath = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataPath);
    
    // Initialize database
    Database database(dataPath);
    if (!database.initialize()) {
        QMessageBox::critical(nullptr, "Database Error", 
            "Failed to initialize database. The application will exit.");
        return 1;
    }
    
    // Create session repository
    SessionRepository repository(&database);
    
    // Create network manager and API client
    QNetworkAccessManager networkManager;
    JulesApiClient apiClient(&networkManager);
    
    // Load API key from settings
    QString apiKey = settings.apiKey();
    qDebug() << "API Key configured:" << !apiKey.isEmpty();
    if (!apiKey.isEmpty()) {
        apiClient.setApiKey(apiKey);
    }
    
    // Create main window
    MainWindow window;
    window.setTheme(settings.theme());
    
    // Add Settings button to toolbar
    QAction* toolbarSettingsAction = window.mainToolbar()->addAction("⚙ Settings");
    QObject::connect(toolbarSettingsAction, &QAction::triggered, [&window]() {
        SettingsDialog dialog(&window);
        dialog.exec();
    });
    
    // Create session list widget (for sidebar)
    SessionListWidget* sessionListWidget = new SessionListWidget(&repository);
    qDebug() << "Created SessionListWidget";
    window.setSidebarContent(sessionListWidget);
    qDebug() << "Set sidebar content";
    
    // Create session detail widget (for main content)
    SessionDetailWidget* sessionDetailWidget = new SessionDetailWidget();
    qDebug() << "Created SessionDetailWidget";
    window.setMainContent(sessionDetailWidget);
    qDebug() << "Set main content";
    
    // Create system tray
    SystemTray systemTray;
    systemTray.setTargetWindow(&window);
    if (systemTray.isAvailable()) {
        systemTray.show();
    }
    
    // Create global hotkey manager
    GlobalHotkeyManager hotkeyManager;
    hotkeyManager.setTargetWindow(&window);
    hotkeyManager.loadSettings();
    hotkeyManager.registerHotkeys();
    
    // Cache for sources (fetched from API)
    QList<Source> cachedSources;
    
    // ========================================================================
    // Connect signals
    // ========================================================================
    
    // Settings changes
    QObject::connect(&settings, &SettingsManager::themeChanged,
                     &window, &MainWindow::setTheme);
    
    QObject::connect(&settings, &SettingsManager::apiKeyChanged, [&]() {
        apiClient.setApiKey(settings.apiKey());
        // Refetch sessions when API key changes
        if (!settings.apiKey().isEmpty()) {
            apiClient.getSessions();
        }
    });
    
    // Menu bar actions
    QObject::connect(&window, &MainWindow::settingsRequested, [&window]() {
        SettingsDialog dialog(&window);
        dialog.exec();
    });
    
    QObject::connect(&window, &MainWindow::quitRequested, []() {
        QApplication::quit();
    });
    
    // System tray actions
    QObject::connect(&systemTray, &SystemTray::settingsRequested, [&window]() {
        SettingsDialog dialog(&window);
        dialog.exec();
    });
    
    QObject::connect(&systemTray, &SystemTray::quitRequested, []() {
        QApplication::quit();
    });
    
    // Session list -> session detail
    QObject::connect(sessionListWidget, &SessionListWidget::sessionSelected, 
                     [&repository, sessionDetailWidget, &apiClient](const QString& sessionId) {
        auto session = repository.getSession(sessionId);
        if (session) {
            sessionDetailWidget->setSession(*session);
            // Fetch latest activities for this session
            apiClient.getActivities(sessionId);
        } else {
            sessionDetailWidget->clear();
        }
    });
    
    // Create new session
    QObject::connect(sessionListWidget, &SessionListWidget::createNewRequested,
                     [&window, &cachedSources, &apiClient]() {
        if (cachedSources.isEmpty()) {
            QMessageBox::information(&window, "No Repositories", 
                "No repositories available. Please configure your API key in Settings.");
            return;
        }
        
        NewSessionDialog dialog(cachedSources, &window);
        QObject::connect(&dialog, &NewSessionDialog::sessionRequested,
                        [&apiClient](const Source& source, const QString& branch, const QString& prompt) {
            apiClient.createSession(source, branch, prompt);
        });
        dialog.exec();
    });
    
    // Session detail -> open URLs
    QObject::connect(sessionDetailWidget, &SessionDetailWidget::openUrlRequested,
                     [](const QString& url) {
        QDesktopServices::openUrl(QUrl(url));
    });
    
    // API client -> session repository
    QObject::connect(&apiClient, &JulesApiClient::sessionsReceived,
                     [&repository, &cachedSources, sessionListWidget](const QList<Session>& sessions, const QString&) {
        repository.saveSessions(sessions);
        
        // Extract sources from sessions for new session dialog
        cachedSources.clear();
        for (const auto& session : sessions) {
            if (session.sourceContext && !session.sourceContext->source.isEmpty()) {
                Source source;
                source.name = session.sourceContext->source;
                source.id = session.sourceContext->source;
                
                // Check if we already have this source
                bool found = false;
                for (const auto& existing : cachedSources) {
                    if (existing.id == source.id) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    cachedSources.append(source);
                }
            }
        }
        
        sessionListWidget->refresh();
    });
    
    QObject::connect(&apiClient, &JulesApiClient::sessionReceived,
                     [&repository, sessionListWidget, sessionDetailWidget](const Session& session) {
        repository.saveSession(session);
        sessionListWidget->refresh();
        
        // Update detail if this is the currently displayed session
        if (!sessionDetailWidget->isEmpty() && 
            sessionDetailWidget->displayedText().contains(session.id)) {
            sessionDetailWidget->setSession(session);
        }
    });
    
    QObject::connect(&apiClient, &JulesApiClient::activitiesReceived,
                     [&repository, sessionDetailWidget](const QString& sessionId, const QList<Activity>& activities) {
        // Get session and update with activities
        auto session = repository.getSession(sessionId);
        if (session) {
            Session updated = *session;
            updated.activities = activities;
            repository.saveSession(updated);
            
            // Update detail widget if showing this session
            sessionDetailWidget->setSession(updated);
        }
    });
    
    QObject::connect(&apiClient, &JulesApiClient::sessionCreated,
                     [&repository, sessionListWidget, sessionDetailWidget, &window](const Session& session) {
        repository.saveSession(session);
        sessionListWidget->refresh();
        sessionDetailWidget->setSession(session);
        window.showFlashMessage("Session created successfully", FlashMessageType::Success);
    });
    
    QObject::connect(&apiClient, &JulesApiClient::errorOccurred,
                     [&window, &systemTray](const ApiError& error) {
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
        
        window.showFlashMessage(message, FlashMessageType::Error);
        systemTray.setState(TrayState::Error);
        
        // Reset tray state after a delay
        QTimer::singleShot(5000, [&systemTray]() {
            systemTray.setState(TrayState::Idle);
        });
    });
    
    // Global hotkey
    QObject::connect(&hotkeyManager, &GlobalHotkeyManager::toggleWindowActivated, [&window]() {
        if (window.isVisible() && window.isActiveWindow()) {
            window.hide();
        } else {
            window.show();
            window.raise();
            window.activateWindow();
        }
    });
    
    // Update tray state based on active sessions
    QObject::connect(&repository, &SessionRepository::sessionsReloaded, [&repository, &systemTray]() {
        auto activeSessions = repository.getActiveSessions();
        if (!activeSessions.isEmpty()) {
            systemTray.setState(TrayState::Active);
            
            // Check if any need attention
            for (const auto& session : activeSessions) {
                if (session.state == SessionState::AwaitingPlanApproval ||
                    session.state == SessionState::AwaitingUserFeedback) {
                    systemTray.setState(TrayState::NeedsAttention);
                    break;
                }
            }
        } else {
            systemTray.setState(TrayState::Idle);
        }
    });
    
    // ========================================================================
    // Initial data load
    // ========================================================================
    
    // Load sessions from local database first
    sessionListWidget->refresh();
    
    // If we have an API key, fetch fresh data from server
    if (!settings.apiKey().isEmpty()) {
        apiClient.getSessions();
    }
    
    // Start polling for session updates
    sessionListWidget->setPollingIntervalMs(30000); // 30 seconds
    sessionListWidget->startPolling();
    
    // Periodic refresh from API (every 60 seconds)
    QTimer* refreshTimer = new QTimer(&app);
    QObject::connect(refreshTimer, &QTimer::timeout, [&apiClient, &settings]() {
        if (!settings.apiKey().isEmpty()) {
            apiClient.getSessions();
        }
    });
    refreshTimer->start(60000);
    
    // ========================================================================
    // Show window and run
    // ========================================================================
    
    window.restoreWindowState();
    window.show();

    int result = app.exec();
    
    // Cleanup
    hotkeyManager.unregisterHotkeys();
    hotkeyManager.saveSettings();
    window.saveWindowState();
    
    return result;
}
