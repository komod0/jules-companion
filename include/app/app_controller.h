#pragma once

#include <QObject>
#include <QList>
#include <memory>

class QNetworkAccessManager;
class QTimer;
class QShortcut;

namespace jules {

class Database;
class SessionRepository;
class DiffsDatabase;
class NetworkMonitor;
class JulesApiClient;
class OfflineSyncManager;
class SharedSyntaxCache;
class DiffPrecomputationService;
class FilenameAutocompleteManager;
class MainWindow;
class SessionListWidget;
class SessionDetailWidget;
class SystemTray;
class TrayPopupWidget;
class GlobalHotkeyManager;
class CommandPalette;
struct Source;

class AppController : public QObject {
    Q_OBJECT

public:
    explicit AppController(QObject* parent = nullptr);
    ~AppController() override;

    void initialize();
    void shutdown();

private:
    void createServices();
    void createUi();
    void connectSignals();
    void setupKeyboardShortcuts();
    void loadInitialData();
    void updateTrayState();

    // Data layer
    std::unique_ptr<Database> m_database;
    std::unique_ptr<SessionRepository> m_repository;
    std::unique_ptr<DiffsDatabase> m_diffsDb;
    std::unique_ptr<NetworkMonitor> m_networkMonitor;
    std::unique_ptr<QNetworkAccessManager> m_networkManager;
    std::unique_ptr<JulesApiClient> m_apiClient;
    std::unique_ptr<OfflineSyncManager> m_offlineSyncManager;
    std::unique_ptr<SharedSyntaxCache> m_syntaxCache;
    std::unique_ptr<DiffPrecomputationService> m_diffPrecompService;
    std::unique_ptr<FilenameAutocompleteManager> m_autocompleteManager;

    // UI layer
    std::unique_ptr<MainWindow> m_window;
    SessionListWidget* m_sessionListWidget = nullptr;   // owned by m_window
    SessionDetailWidget* m_sessionDetailWidget = nullptr; // owned by m_window
    std::unique_ptr<SystemTray> m_systemTray;
    TrayPopupWidget* m_trayPopup = nullptr;             // top-level widget
    std::unique_ptr<GlobalHotkeyManager> m_hotkeyManager;
    CommandPalette* m_commandPalette = nullptr;          // owned by m_window

    // Shortcuts (owned by m_window)
    QShortcut* m_shortcutNew = nullptr;
    QShortcut* m_shortcutRefresh = nullptr;
    QShortcut* m_shortcutFind = nullptr;
    QShortcut* m_shortcutCommandPalette = nullptr;

    // Timers
    QTimer* m_refreshTimer = nullptr;

    // Cached data
    QList<Source> m_cachedSources;
};

} // namespace jules
