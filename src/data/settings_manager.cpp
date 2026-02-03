#include "data/settings_manager.h"
#include <QSysInfo>
#include <QByteArray>
#include <algorithm>

namespace {

const int MIN_FONT_SIZE = 9;
const int MAX_FONT_SIZE = 24;
const int DEFAULT_ACTIVITY_FONT_SIZE = 12;
const int DEFAULT_DIFF_FONT_SIZE = 11;

QString machineId() {
    // Use Qt's machine unique ID
    return QSysInfo::machineUniqueId().toHex();
}

QString obfuscate(const QString& plaintext, const QString& key) {
    QByteArray data = plaintext.toUtf8();
    QByteArray keyBytes = key.toUtf8();

    if (keyBytes.isEmpty()) {
        return QString::fromLatin1(data.toBase64());
    }

    for (int i = 0; i < data.size(); ++i) {
        data[i] = data[i] ^ keyBytes[i % keyBytes.size()];
    }

    return QString::fromLatin1(data.toBase64());
}

QString deobfuscate(const QString& encoded, const QString& key) {
    QByteArray data = QByteArray::fromBase64(encoded.toLatin1());
    QByteArray keyBytes = key.toUtf8();

    if (keyBytes.isEmpty()) {
        return {}; // Or handle error appropriately
    }

    for (int i = 0; i < data.size(); ++i) {
        data[i] = data[i] ^ keyBytes[i % keyBytes.size()];
    }

    return QString::fromUtf8(data);
}

} // anonymous namespace

SettingsManager& SettingsManager::instance() {
    static SettingsManager instance;
    return instance;
}

SettingsManager::SettingsManager(QObject* parent)
    : QObject(parent), m_settings("JulesLinux", "Jules") 
{
    qRegisterMetaType<Theme>("Theme");
}

QString SettingsManager::apiKey() const {
    QString encoded = m_settings.value("api/keyEncoded").toString();
    if (encoded.isEmpty()) return {};
    return deobfuscate(encoded, machineId());
}

void SettingsManager::setApiKey(const QString& key) {
    if (key.isEmpty()) {
        m_settings.remove("api/keyEncoded");
    } else {
        QString encoded = obfuscate(key, machineId());
        m_settings.setValue("api/keyEncoded", encoded);
    }
    emit apiKeyChanged();
}

Theme SettingsManager::theme() const {
    int value = m_settings.value("appearance/theme", static_cast<int>(Theme::System)).toInt();
    return static_cast<Theme>(value);
}

void SettingsManager::setTheme(Theme theme) {
    Theme current = this->theme();
    if (current == theme) return;
    
    m_settings.setValue("appearance/theme", static_cast<int>(theme));
    emit themeChanged(theme);
}

bool SettingsManager::notificationsEnabled() const {
    return m_settings.value("notifications/enabled", true).toBool();
}

void SettingsManager::setNotificationsEnabled(bool enabled) {
    bool current = notificationsEnabled();
    if (current == enabled) return;
    
    m_settings.setValue("notifications/enabled", enabled);
    emit notificationsEnabledChanged(enabled);
}

int SettingsManager::activityFontSize() const {
    return m_settings.value("appearance/activityFontSize", DEFAULT_ACTIVITY_FONT_SIZE).toInt();
}

void SettingsManager::setActivityFontSize(int size) {
    size = clampFontSize(size);
    if (activityFontSize() == size) return;
    
    m_settings.setValue("appearance/activityFontSize", size);
    emit fontSizeChanged();
}

int SettingsManager::diffFontSize() const {
    return m_settings.value("appearance/diffFontSize", DEFAULT_DIFF_FONT_SIZE).toInt();
}

void SettingsManager::setDiffFontSize(int size) {
    size = clampFontSize(size);
    if (diffFontSize() == size) return;
    
    m_settings.setValue("appearance/diffFontSize", size);
    emit fontSizeChanged();
}

int SettingsManager::clampFontSize(int size) const {
    return std::clamp(size, MIN_FONT_SIZE, MAX_FONT_SIZE);
}

void SettingsManager::sync() {
    m_settings.sync();
}
