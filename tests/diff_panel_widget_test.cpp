#include <gtest/gtest.h>
#include <QApplication>

#include "ui/diff_panel_widget.h"

namespace jules {
namespace test {

class DiffPanelWidgetTest : public ::testing::Test {
protected:
};

TEST_F(DiffPanelWidgetTest, CanConstruct) {
    DiffPanelWidget widget;
    SUCCEED();
}

TEST_F(DiffPanelWidgetTest, InitialLoadingStateFalse) {
    DiffPanelWidget widget;
    EXPECT_FALSE(widget.isLoading());
}

TEST_F(DiffPanelWidgetTest, SetLoadingTrue) {
    DiffPanelWidget widget;
    widget.setLoading(true);
    EXPECT_TRUE(widget.isLoading());
}

TEST_F(DiffPanelWidgetTest, SetLoadingFalse) {
    DiffPanelWidget widget;
    widget.setLoading(true);
    widget.setLoading(false);
    EXPECT_FALSE(widget.isLoading());
}

TEST_F(DiffPanelWidgetTest, ReleaseResourcesDoesNotCrash) {
    DiffPanelWidget widget;
    // releaseResources before GL init should be a no-op (m_initialized is false)
    EXPECT_NO_THROW(widget.releaseResources());
}

TEST_F(DiffPanelWidgetTest, SetDiffsWithEmptyList) {
    DiffPanelWidget widget;
    QList<CachedDiff> empty;
    EXPECT_NO_THROW(widget.setDiffs(empty));
}

TEST_F(DiffPanelWidgetTest, SetDiffsWithData) {
    DiffPanelWidget widget;
    CachedDiff diff;
    diff.patch = "+added line\n-removed line\n context\n";
    diff.filename = "test.cpp";
    diff.language = "cpp";
    QList<CachedDiff> diffs;
    diffs.append(diff);
    EXPECT_NO_THROW(widget.setDiffs(diffs));
}

TEST_F(DiffPanelWidgetTest, SetLoadingToggle) {
    DiffPanelWidget widget;
    widget.setLoading(true);
    EXPECT_TRUE(widget.isLoading());
    widget.setLoading(false);
    EXPECT_FALSE(widget.isLoading());
    widget.setLoading(true);
    EXPECT_TRUE(widget.isLoading());
}

// ============================================================================
// Dark Mode / Theme Switch Safety Tests
//
// The theme crash (segfault) was caused by calling setDarkMode() inside
// paintGL() during Qt's stylesheet re-polishing cycle. The fix moved theme
// updates to updateDarkMode() which is called from a signal outside paint.
// These tests verify updateDarkMode() is safe in all widget states.
// ============================================================================

TEST_F(DiffPanelWidgetTest, UpdateDarkModeBeforeGLInit) {
    // Before initializeGL, updateDarkMode should be a safe no-op
    DiffPanelWidget widget;
    EXPECT_NO_THROW(widget.updateDarkMode(true));
    EXPECT_NO_THROW(widget.updateDarkMode(false));
}

TEST_F(DiffPanelWidgetTest, UpdateDarkModeToggle) {
    // Rapidly toggling dark mode should not crash
    DiffPanelWidget widget;
    for (int i = 0; i < 10; ++i) {
        EXPECT_NO_THROW(widget.updateDarkMode(i % 2 == 0));
    }
}

TEST_F(DiffPanelWidgetTest, UpdateDarkModeSameValueNoOp) {
    // Calling with same value should be a no-op (short-circuit)
    DiffPanelWidget widget;
    EXPECT_NO_THROW(widget.updateDarkMode(true));
    EXPECT_NO_THROW(widget.updateDarkMode(true));  // same value
    EXPECT_NO_THROW(widget.updateDarkMode(false));
    EXPECT_NO_THROW(widget.updateDarkMode(false)); // same value
}

TEST_F(DiffPanelWidgetTest, UpdateDarkModeWithDiffsLoaded) {
    // Theme change after diffs are set should not crash
    DiffPanelWidget widget;
    CachedDiff diff;
    diff.patch = "+added\n-removed\n context\n";
    diff.filename = "test.cpp";
    diff.language = "cpp";
    QList<CachedDiff> diffs;
    diffs.append(diff);
    widget.setDiffs(diffs);

    EXPECT_NO_THROW(widget.updateDarkMode(false));
    EXPECT_NO_THROW(widget.updateDarkMode(true));
}

TEST_F(DiffPanelWidgetTest, UpdateDarkModeWhileLoading) {
    // Theme change during loading animation should not crash
    DiffPanelWidget widget;
    widget.setLoading(true);
    EXPECT_NO_THROW(widget.updateDarkMode(false));
    EXPECT_NO_THROW(widget.updateDarkMode(true));
    widget.setLoading(false);
}

TEST_F(DiffPanelWidgetTest, UpdateDarkModeAfterReleaseResources) {
    // Theme change after resources released should be safe
    DiffPanelWidget widget;
    widget.releaseResources();
    EXPECT_NO_THROW(widget.updateDarkMode(true));
    EXPECT_NO_THROW(widget.updateDarkMode(false));
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
