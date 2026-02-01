#include <gtest/gtest.h>
#include <QCoreApplication>
#include <QSignalSpy>
#include "core/settings_manager.h"

// Test fixture for SettingsManager
class SettingsManagerTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Ensure a clean slate for each test
        QSettings settings;
        settings.clear();
        settings.sync();
    }
};

TEST_F(SettingsManagerTest, Singleton) {
    jules::SettingsManager& instance1 = jules::SettingsManager::instance();
    jules::SettingsManager& instance2 = jules::SettingsManager::instance();
    ASSERT_EQ(&instance1, &instance2);
}

TEST_F(SettingsManagerTest, ApiKey) {
    jules::SettingsManager& sm = jules::SettingsManager::instance();
    ASSERT_EQ(sm.apiKey(), "");

    QSignalSpy spy(&sm, &jules::SettingsManager::apiKeyChanged);
    sm.setApiKey("test-key");
    ASSERT_EQ(sm.apiKey(), "test-key");
    ASSERT_EQ(spy.count(), 1);

    // Setting same key should not emit signal
    sm.setApiKey("test-key");
    ASSERT_EQ(spy.count(), 1);
}

TEST_F(SettingsManagerTest, Theme) {
    jules::SettingsManager& sm = jules::SettingsManager::instance();
    ASSERT_EQ(sm.theme(), jules::Theme::System);

    QSignalSpy spy(&sm, &jules::SettingsManager::themeChanged);
    sm.setTheme(jules::Theme::Dark);
    ASSERT_EQ(sm.theme(), jules::Theme::Dark);
    ASSERT_EQ(spy.count(), 1);
    QList<QVariant> arguments = spy.takeFirst();
    ASSERT_EQ(static_cast<jules::Theme>(arguments.at(0).toInt()), jules::Theme::Dark);
}

TEST_F(SettingsManagerTest, ActivityFontSize) {
    jules::SettingsManager& sm = jules::SettingsManager::instance();
    ASSERT_FLOAT_EQ(sm.activityFontSize(), 12.0f);

    QSignalSpy spy(&sm, &jules::SettingsManager::fontSizeChanged);
    sm.setActivityFontSize(14.0f);
    ASSERT_FLOAT_EQ(sm.activityFontSize(), 14.0f);
    ASSERT_EQ(spy.count(), 1);

    // Test validation (invalid size)
    sm.setActivityFontSize(8.0f);
    ASSERT_FLOAT_EQ(sm.activityFontSize(), 14.0f); // Should not change
    ASSERT_EQ(spy.count(), 1); // Signal should not be emitted

    // Test validation (valid size)
    sm.setActivityFontSize(24.0f);
    ASSERT_FLOAT_EQ(sm.activityFontSize(), 24.0f);
    ASSERT_EQ(spy.count(), 2);
}

TEST_F(SettingsManagerTest, DiffFontSize) {
    jules::SettingsManager& sm = jules::SettingsManager::instance();
    ASSERT_FLOAT_EQ(sm.diffFontSize(), 11.0f);

    QSignalSpy spy(&sm, &jules::SettingsManager::fontSizeChanged);

    sm.setDiffFontSize(13.0f);
    ASSERT_FLOAT_EQ(sm.diffFontSize(), 13.0f);
    ASSERT_EQ(spy.count(), 1);

    // Test validation
    sm.setDiffFontSize(25.0f);
    ASSERT_FLOAT_EQ(sm.diffFontSize(), 13.0f); // Should not change
    ASSERT_EQ(spy.count(), 1);
}

TEST_F(SettingsManagerTest, Notifications) {
    jules::SettingsManager& sm = jules::SettingsManager::instance();
    ASSERT_TRUE(sm.notificationsEnabled());

    QSignalSpy spy(&sm, &jules::SettingsManager::notificationsEnabledChanged);
    sm.setNotificationsEnabled(false);
    ASSERT_FALSE(sm.notificationsEnabled());
    ASSERT_EQ(spy.count(), 1);
    QList<QVariant> arguments = spy.takeFirst();
    ASSERT_FALSE(arguments.at(0).toBool());
}

TEST_F(SettingsManagerTest, Persistence) {
    jules::SettingsManager& sm = jules::SettingsManager::instance();
    sm.setApiKey("persistent-key");
    sm.setTheme(jules::Theme::Light);
    sm.setDiffFontSize(20.0f);
    sm.sync();

    // Use a separate QSettings object to verify persistence
    QSettings settings;
    ASSERT_EQ(settings.value("api/keyEncoded").toString(), "persistent-key");
    ASSERT_EQ(static_cast<jules::Theme>(settings.value("appearance/theme").toInt()), jules::Theme::Light);
    ASSERT_FLOAT_EQ(settings.value("appearance/diffFontSize").toFloat(), 20.0f);
}
