#include "core/settings_manager.h"
#include <QtGlobal>

namespace jules {

namespace {
    // QSettings Keys
    const QString KEY_API_KEY = QStringLiteral("api/keyEncoded");
    const QString KEY_THEME = QStringLiteral("appearance/theme");
    const QString KEY_ACTIVITY_FONT_SIZE = QStringLiteral("appearance/activityFontSize");
    const QString KEY_DIFF_FONT_SIZE = QStringLiteral("appearance/diffFontSize");
    const QString KEY_NOTIFICATIONS = QStringLiteral("general/notifications");
}

SettingsManager& SettingsManager::instance() {
    static SettingsManager instance;
    return instance;
}

SettingsManager::SettingsManager(QObject* parent)
    : QObject(parent) {}

// API
QString SettingsManager::apiKey() const {
    return m_settings.value(KEY_API_KEY, "").toString();
}

void SettingsManager::setApiKey(const QString& key) {
    if (apiKey() != key) {
        m_settings.setValue(KEY_API_KEY, key);
        emit apiKeyChanged();
    }
}

// Appearance
Theme SettingsManager::theme() const {
    return static_cast<Theme>(m_settings.value(KEY_THEME, static_cast<int>(Theme::System)).toInt());
}

void SettingsManager::setTheme(Theme theme) {
    if (this->theme() != theme) {
        m_settings.setValue(KEY_THEME, static_cast<int>(theme));
        emit themeChanged(theme);
    }
}

float SettingsManager::activityFontSize() const {
    return m_settings.value(KEY_ACTIVITY_FONT_SIZE, 12.0f).toFloat();
}

void SettingsManager::setActivityFontSize(float size) {
    if (size >= 9.0f && size <= 24.0f) {
        if (activityFontSize() != size) {
            m_settings.setValue(KEY_ACTIVITY_FONT_SIZE, size);
            emit fontSizeChanged();
        }
    }
}

float SettingsManager::diffFontSize() const {
    return m_settings.value(KEY_DIFF_FONT_SIZE, 11.0f).toFloat();
}

void SettingsManager::setDiffFontSize(float size) {
    if (size >= 9.0f && size <= 24.0f) {
        if (diffFontSize() != size) {
            m_settings.setValue(KEY_DIFF_FONT_SIZE, size);
            emit fontSizeChanged();
        }
    }
}

// General
bool SettingsManager::notificationsEnabled() const {
    return m_settings.value(KEY_NOTIFICATIONS, true).toBool();
}

void SettingsManager::setNotificationsEnabled(bool enabled) {
    if (notificationsEnabled() != enabled) {
        m_settings.setValue(KEY_NOTIFICATIONS, enabled);
        emit notificationsEnabledChanged(enabled);
    }
}

// Persistence
void SettingsManager::sync() {
    m_settings.sync();
}

} // namespace jules
