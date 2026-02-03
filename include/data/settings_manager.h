#pragma once

#include <QObject>
#include <QString>
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

    void sync();

signals:
    void apiKeyChanged();
    void themeChanged(Theme theme);
    void notificationsEnabledChanged(bool enabled);
    void fontSizeChanged();

private:
    SettingsManager(QObject* parent = nullptr);
    ~SettingsManager() = default;

    SettingsManager(const SettingsManager&) = delete;
    SettingsManager& operator=(const SettingsManager&) = delete;
    
    int clampFontSize(int size) const;

    QSettings m_settings;
};
