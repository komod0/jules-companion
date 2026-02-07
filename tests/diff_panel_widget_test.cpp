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

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
