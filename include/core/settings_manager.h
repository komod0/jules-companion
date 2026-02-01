#pragma once

#include <QObject>
#include <QSettings>
#include "core/theme.h"

namespace jules {

class SettingsManager : public QObject {
    Q_OBJECT
public:
    static SettingsManager& instance();

    // API
    QString apiKey() const;
    void setApiKey(const QString& key);

    // Appearance
    Theme theme() const;
    void setTheme(Theme theme);
    float activityFontSize() const;
    void setActivityFontSize(float size);
    float diffFontSize() const;
    void setDiffFontSize(float size);

    // General
    bool notificationsEnabled() const;
    void setNotificationsEnabled(bool enabled);

    // Persistence
    void sync();

signals:
    void themeChanged(Theme theme);
    void fontSizeChanged();
    void apiKeyChanged();
    void notificationsEnabledChanged(bool enabled);

private:
    SettingsManager(QObject* parent = nullptr);
    ~SettingsManager() = default;

    QSettings m_settings;
};

} // namespace jules
