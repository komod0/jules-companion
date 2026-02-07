#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QSettings>

enum class Theme {
    System = 0,
    Light = 1,
    Dark = 2
};

Q_DECLARE_METATYPE(Theme)

class SettingsManager : public QObject {
    Q_OBJECT

public:
    static SettingsManager& instance();

    // API Key
    QString apiKey() const;
    void setApiKey(const QString& key);

    // Theme
    Theme theme() const;
    void setTheme(Theme theme);
    
    // Notifications
    bool notificationsEnabled() const;
    void setNotificationsEnabled(bool enabled);
    
    // Font sizes
    int activityFontSize() const;
    void setActivityFontSize(int size);
    
    int diffFontSize() const;
    void setDiffFontSize(int size);
    
    // Launch at Login
    bool launchAtLoginEnabled() const;
    void setLaunchAtLoginEnabled(bool enabled);
    
    // AI Summaries
    bool aiSummariesEnabled() const;
    void setAiSummariesEnabled(bool enabled);
    QString geminiApiKey() const;
    void setGeminiApiKey(const QString& key);

    // Repository Folders (local paths for merge/autocomplete)
    QStringList repositoryFolders() const;
    void setRepositoryFolders(const QStringList& folders);
    void addRepositoryFolder(const QString& folder);
    void removeRepositoryFolder(const QString& folder);

    void sync();

signals:
    void apiKeyChanged();
    void themeChanged(Theme theme);
    void notificationsEnabledChanged(bool enabled);
    void fontSizeChanged();
    void launchAtLoginChanged(bool enabled);
    void aiSummariesEnabledChanged(bool enabled);
    void repositoryFoldersChanged();

private:
    SettingsManager(QObject* parent = nullptr);
    ~SettingsManager() = default;

    SettingsManager(const SettingsManager&) = delete;
    SettingsManager& operator=(const SettingsManager&) = delete;
    
    int clampFontSize(int size) const;

    QSettings m_settings;
};
