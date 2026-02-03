#include <gtest/gtest.h>
#include <QSignalSpy>
#include <QSettings>
#include <QApplication>
#include <QDebug>
#include <QSysInfo>

#include "data/settings_manager.h"

namespace jules {
namespace test {

class SettingsManagerTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Clear settings before each test
        QSettings settings("JulesLinux", "Jules");
        settings.clear();
        settings.sync();
    }
    
    void TearDown() override {
        // Clear settings after each test
        QSettings settings("JulesLinux", "Jules");
        settings.clear();
        settings.sync();
    }
};

// ============================================================================
// Singleton Tests
// ============================================================================

TEST_F(SettingsManagerTest, SingletonReturnsInstance) {
    SettingsManager& mgr1 = SettingsManager::instance();
    SettingsManager& mgr2 = SettingsManager::instance();
    EXPECT_EQ(&mgr1, &mgr2);
}

// ============================================================================
// API Key Tests
// ============================================================================

TEST_F(SettingsManagerTest, ApiKeyNotStoredPlaintext) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setApiKey("sk-test-12345");
    mgr.sync();

    QSettings settings("JulesLinux", "Jules");
    QString stored = settings.value("api/keyEncoded").toString();

    EXPECT_FALSE(stored.contains("sk-test-12345"));
    EXPECT_FALSE(stored.isEmpty());
}

TEST_F(SettingsManagerTest, ApiKeyRoundTrip) {
    // Skip if machine ID is not available (common in CI containers)
    QByteArray machineId = QSysInfo::machineUniqueId();
    if (machineId.isEmpty()) {
        GTEST_SKIP() << "Machine ID not available (common in CI containers)";
    }
    
    SettingsManager& mgr = SettingsManager::instance();
    QString original = "sk-jules-api-key-12345";

    mgr.setApiKey(original);
    QString retrieved = mgr.apiKey();

    EXPECT_EQ(retrieved, original);
}

TEST_F(SettingsManagerTest, EmptyKeyRemovesSetting) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setApiKey("some-key");
    mgr.sync();

    mgr.setApiKey("");
    mgr.sync();

    QSettings settings("JulesLinux", "Jules");
    EXPECT_FALSE(settings.contains("api/keyEncoded"));
}

TEST_F(SettingsManagerTest, ApiKeyChangeEmitsSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    QSignalSpy spy(&mgr, &SettingsManager::apiKeyChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setApiKey("new-api-key");
    
    EXPECT_EQ(spy.count(), 1);
}

// ============================================================================
// Theme Tests
// ============================================================================

TEST_F(SettingsManagerTest, DefaultThemeIsSystem) {
    SettingsManager& mgr = SettingsManager::instance();
    EXPECT_EQ(mgr.theme(), Theme::System);
}

TEST_F(SettingsManagerTest, ThemePersists) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setTheme(Theme::Dark);
    mgr.sync();

    // Read directly from QSettings to verify persistence
    QSettings settings("JulesLinux", "Jules");
    int themeValue = settings.value("appearance/theme", -1).toInt();
    EXPECT_EQ(themeValue, static_cast<int>(Theme::Dark));
}

TEST_F(SettingsManagerTest, ThemeChangeEmitsSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    QSignalSpy spy(&mgr, &SettingsManager::themeChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setTheme(Theme::Light);
    
    EXPECT_EQ(spy.count(), 1);
    EXPECT_EQ(spy.at(0).at(0).value<Theme>(), Theme::Light);
}

TEST_F(SettingsManagerTest, SameThemeDoesNotEmitSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setTheme(Theme::Dark);
    
    QSignalSpy spy(&mgr, &SettingsManager::themeChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setTheme(Theme::Dark);  // Same theme
    
    EXPECT_EQ(spy.count(), 0);
}

TEST_F(SettingsManagerTest, AllThemeValuesWork) {
    SettingsManager& mgr = SettingsManager::instance();
    
    mgr.setTheme(Theme::System);
    EXPECT_EQ(mgr.theme(), Theme::System);
    
    mgr.setTheme(Theme::Light);
    EXPECT_EQ(mgr.theme(), Theme::Light);
    
    mgr.setTheme(Theme::Dark);
    EXPECT_EQ(mgr.theme(), Theme::Dark);
}

// ============================================================================
// Notifications Tests
// ============================================================================

TEST_F(SettingsManagerTest, DefaultNotificationsEnabled) {
    SettingsManager& mgr = SettingsManager::instance();
    EXPECT_TRUE(mgr.notificationsEnabled());
}

TEST_F(SettingsManagerTest, NotificationsCanBeDisabled) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setNotificationsEnabled(false);
    EXPECT_FALSE(mgr.notificationsEnabled());
}

TEST_F(SettingsManagerTest, NotificationsChangeEmitsSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    QSignalSpy spy(&mgr, &SettingsManager::notificationsEnabledChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setNotificationsEnabled(false);
    
    EXPECT_EQ(spy.count(), 1);
    EXPECT_FALSE(spy.at(0).at(0).toBool());
}

TEST_F(SettingsManagerTest, SameNotificationValueDoesNotEmitSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setNotificationsEnabled(true);
    
    QSignalSpy spy(&mgr, &SettingsManager::notificationsEnabledChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setNotificationsEnabled(true);  // Same value
    
    EXPECT_EQ(spy.count(), 0);
}

// ============================================================================
// Font Size Tests
// ============================================================================

TEST_F(SettingsManagerTest, DefaultActivityFontSize) {
    SettingsManager& mgr = SettingsManager::instance();
    EXPECT_EQ(mgr.activityFontSize(), 12);
}

TEST_F(SettingsManagerTest, DefaultDiffFontSize) {
    SettingsManager& mgr = SettingsManager::instance();
    EXPECT_EQ(mgr.diffFontSize(), 11);
}

TEST_F(SettingsManagerTest, FontSizeValidation_BelowMinimum) {
    SettingsManager& mgr = SettingsManager::instance();
    
    mgr.setActivityFontSize(5);  // Below minimum (9)
    EXPECT_GE(mgr.activityFontSize(), 9);
}

TEST_F(SettingsManagerTest, FontSizeValidation_AboveMaximum) {
    SettingsManager& mgr = SettingsManager::instance();
    
    mgr.setActivityFontSize(30);  // Above maximum (24)
    EXPECT_LE(mgr.activityFontSize(), 24);
}

TEST_F(SettingsManagerTest, FontSizeValidValue) {
    SettingsManager& mgr = SettingsManager::instance();
    
    mgr.setActivityFontSize(14);
    EXPECT_EQ(mgr.activityFontSize(), 14);
    
    mgr.setDiffFontSize(16);
    EXPECT_EQ(mgr.diffFontSize(), 16);
}

TEST_F(SettingsManagerTest, FontSizeChangeEmitsSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    QSignalSpy spy(&mgr, &SettingsManager::fontSizeChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setActivityFontSize(15);
    
    EXPECT_EQ(spy.count(), 1);
}

TEST_F(SettingsManagerTest, SameFontSizeDoesNotEmitSignal) {
    SettingsManager& mgr = SettingsManager::instance();
    mgr.setActivityFontSize(14);
    
    QSignalSpy spy(&mgr, &SettingsManager::fontSizeChanged);
    ASSERT_TRUE(spy.isValid());
    
    mgr.setActivityFontSize(14);  // Same value
    
    EXPECT_EQ(spy.count(), 0);
}

// ============================================================================
// Persistence Tests
// ============================================================================

TEST_F(SettingsManagerTest, AllSettingsPersist) {
    SettingsManager& mgr = SettingsManager::instance();
    
    // Set all settings
    mgr.setApiKey("test-key");
    mgr.setTheme(Theme::Dark);
    mgr.setNotificationsEnabled(false);
    mgr.setActivityFontSize(16);
    mgr.setDiffFontSize(14);
    mgr.sync();
    
    // Verify via QSettings
    QSettings settings("JulesLinux", "Jules");
    EXPECT_TRUE(settings.contains("api/keyEncoded"));
    EXPECT_EQ(settings.value("appearance/theme").toInt(), static_cast<int>(Theme::Dark));
    EXPECT_FALSE(settings.value("notifications/enabled").toBool());
    EXPECT_EQ(settings.value("appearance/activityFontSize").toInt(), 16);
    EXPECT_EQ(settings.value("appearance/diffFontSize").toInt(), 14);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
