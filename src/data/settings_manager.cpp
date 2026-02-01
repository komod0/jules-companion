#include "data/settings_manager.h"
#include <QSysInfo>
#include <QByteArray>

namespace {

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
    : QObject(parent), m_settings("JulesLinux", "Jules") {}

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

void SettingsManager::sync() {
    m_settings.sync();
}
