#pragma once

#include <QObject>
#include <QString>
#include <QSettings>

class SettingsManager : public QObject {
    Q_OBJECT

public:
    static SettingsManager& instance();

    QString apiKey() const;
    void setApiKey(const QString& key);

    void sync();

signals:
    void apiKeyChanged();

private:
    SettingsManager(QObject* parent = nullptr);
    ~SettingsManager() = default;

    SettingsManager(const SettingsManager&) = delete;
    SettingsManager& operator=(const SettingsManager&) = delete;

    QSettings m_settings;
};
