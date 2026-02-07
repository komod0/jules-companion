#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>

#include "ui/update_checker.h"

namespace jules {
namespace test {

class UpdateCheckerTest : public ::testing::Test {
protected:
};

// ============================================================================
// Construction & defaults
// ============================================================================

TEST_F(UpdateCheckerTest, CanConstruct) {
    EXPECT_NO_THROW({
        UpdateChecker checker;
    });
}

TEST_F(UpdateCheckerTest, DefaultVersionIsNotEmpty) {
    UpdateChecker checker;
    // UpdateChecker has a built-in default version
    EXPECT_FALSE(checker.currentVersion().isEmpty());
}

TEST_F(UpdateCheckerTest, DefaultAutoCheckEnabled) {
    UpdateChecker checker;
    EXPECT_TRUE(checker.isAutoCheckEnabled());
}

TEST_F(UpdateCheckerTest, DefaultCheckIntervalIsPositive) {
    UpdateChecker checker;
    EXPECT_GT(checker.checkIntervalHours(), 0);
}

TEST_F(UpdateCheckerTest, DefaultNotChecking) {
    UpdateChecker checker;
    EXPECT_FALSE(checker.isChecking());
}

TEST_F(UpdateCheckerTest, DefaultNotDownloading) {
    UpdateChecker checker;
    EXPECT_FALSE(checker.isDownloading());
}

TEST_F(UpdateCheckerTest, DefaultNoUpdateAvailable) {
    UpdateChecker checker;
    EXPECT_FALSE(checker.hasUpdate());
}

// ============================================================================
// Configuration
// ============================================================================

TEST_F(UpdateCheckerTest, SetCurrentVersionUpdates) {
    UpdateChecker checker;
    checker.setCurrentVersion("1.2.3");
    EXPECT_EQ(checker.currentVersion(), "1.2.3");
}

TEST_F(UpdateCheckerTest, SetGitHubRepoDoesNotCrash) {
    UpdateChecker checker;
    EXPECT_NO_THROW({
        checker.setGitHubRepo("owner", "repo");
    });
}

TEST_F(UpdateCheckerTest, SetCheckInterval) {
    UpdateChecker checker;
    checker.setCheckInterval(12);
    EXPECT_EQ(checker.checkIntervalHours(), 12);
}

TEST_F(UpdateCheckerTest, AutoCheckDisableEnable) {
    UpdateChecker checker;
    checker.setAutoCheck(false);
    EXPECT_FALSE(checker.isAutoCheckEnabled());

    checker.setAutoCheck(true);
    EXPECT_TRUE(checker.isAutoCheckEnabled());
}

TEST_F(UpdateCheckerTest, SetIncludePrereleasesDoesNotCrash) {
    UpdateChecker checker;
    EXPECT_NO_THROW({
        checker.setIncludePrereleases(true);
        checker.setIncludePrereleases(false);
    });
}

// ============================================================================
// Signals
// ============================================================================

TEST_F(UpdateCheckerTest, CheckStartedSignalIsValid) {
    UpdateChecker checker;
    QSignalSpy spy(&checker, &UpdateChecker::checkStarted);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(UpdateCheckerTest, CheckFinishedSignalIsValid) {
    UpdateChecker checker;
    QSignalSpy spy(&checker, &UpdateChecker::checkFinished);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(UpdateCheckerTest, CheckFailedSignalIsValid) {
    UpdateChecker checker;
    QSignalSpy spy(&checker, &UpdateChecker::checkFailed);
    EXPECT_TRUE(spy.isValid());
}

// ============================================================================
// State
// ============================================================================

TEST_F(UpdateCheckerTest, CancelDownloadWhenIdleDoesNotCrash) {
    UpdateChecker checker;
    EXPECT_NO_THROW({
        checker.cancelDownload();
    });
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
