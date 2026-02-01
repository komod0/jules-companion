#include <gtest/gtest.h>
#include "data/settings_manager.h"
#include <QSettings>
#include <QDebug>

TEST(SettingsManagerTest, ApiKeyNotStoredPlaintext) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setApiKey("sk-test-12345");
    mgr.sync();

    QSettings settings("JulesLinux", "Jules");
    QString stored = settings.value("api/keyEncoded").toString();

    EXPECT_FALSE(stored.contains("sk-test-12345"));
    EXPECT_FALSE(stored.isEmpty());
}

TEST(SettingsManagerTest, ApiKeyRoundTrip) {
    SettingsManager& mgr = SettingsManager::instance();
    QString original = "sk-jules-api-key-12345";

    mgr.setApiKey(original);
    QString retrieved = mgr.apiKey();

    EXPECT_EQ(retrieved, original);
}

TEST(SettingsManagerTest, EmptyKeyRemovesSetting) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setApiKey("some-key");
    mgr.sync();

    mgr.setApiKey("");
    mgr.sync();

    QSettings settings("JulesLinux", "Jules");
    EXPECT_FALSE(settings.contains("api/keyEncoded"));
}
