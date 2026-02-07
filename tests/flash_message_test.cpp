#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QLabel>
#include <QTimer>
#include <QEventLoop>

#include "ui/flash_message_widget.h"

namespace jules {
namespace test {

class FlashMessageTest : public ::testing::Test {
protected:
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }
};

// ============================================================================
// Construction Tests
// ============================================================================

TEST_F(FlashMessageTest, ConstructionDoesNotCrash) {
    EXPECT_NO_THROW({
        FlashMessageWidget widget;
    });
}

TEST_F(FlashMessageTest, InitiallyNotVisible) {
    FlashMessageWidget widget;
    EXPECT_FALSE(widget.isVisible());
}

TEST_F(FlashMessageTest, InitialOpacityIsOne) {
    FlashMessageWidget widget;
    EXPECT_DOUBLE_EQ(widget.opacity(), 1.0);
}

// ============================================================================
// Show Message Tests
// ============================================================================

TEST_F(FlashMessageTest, ShowMessageMakesVisible) {
    FlashMessageWidget widget;
    EXPECT_FALSE(widget.isVisible());

    widget.showMessage("Hello");
    EXPECT_TRUE(widget.isVisible());
}

TEST_F(FlashMessageTest, ShowMessageSetsLabelText) {
    FlashMessageWidget widget;
    widget.showMessage("Test message");

    QLabel* label = widget.findChild<QLabel*>();
    ASSERT_NE(label, nullptr);
    EXPECT_EQ(label->text(), QString("Test message"));
}

TEST_F(FlashMessageTest, ShowMessageInfoTypeDoesNotCrash) {
    FlashMessageWidget widget;
    EXPECT_NO_THROW({
        widget.showMessage("Info", FlashMessageType::Info);
    });
}

TEST_F(FlashMessageTest, ShowMessageAllTypesDoNotCrash) {
    FlashMessageWidget widget;
    EXPECT_NO_THROW({
        widget.showMessage("Success", FlashMessageType::Success);
        widget.showMessage("Warning", FlashMessageType::Warning);
        widget.showMessage("Error", FlashMessageType::Error);
        widget.showMessage("Info", FlashMessageType::Info);
    });
}

// ============================================================================
// Opacity Tests
// ============================================================================

TEST_F(FlashMessageTest, SetOpacityUpdatesValue) {
    FlashMessageWidget widget;
    widget.setOpacity(0.5);
    EXPECT_DOUBLE_EQ(widget.opacity(), 0.5);
}

TEST_F(FlashMessageTest, OpacityReturnsSetValue) {
    FlashMessageWidget widget;
    widget.setOpacity(0.75);
    qreal val = widget.opacity();
    EXPECT_DOUBLE_EQ(val, 0.75);
}

TEST_F(FlashMessageTest, SetOpacityToZeroWorks) {
    FlashMessageWidget widget;
    widget.setOpacity(0.0);
    EXPECT_DOUBLE_EQ(widget.opacity(), 0.0);
}

// ============================================================================
// Dismiss Tests
// ============================================================================

TEST_F(FlashMessageTest, DismissedSignalIsValid) {
    FlashMessageWidget widget;
    QSignalSpy spy(&widget, &FlashMessageWidget::dismissed);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(FlashMessageTest, HideMakesNotVisible) {
    FlashMessageWidget widget;
    widget.showMessage("Visible");
    EXPECT_TRUE(widget.isVisible());

    widget.hide();
    // The fade animation runs; process events until it finishes
    processEvents(400);
    EXPECT_FALSE(widget.isVisible());
}

TEST_F(FlashMessageTest, DismissTimerFiresAfterDuration) {
    FlashMessageWidget widget;
    QSignalSpy spy(&widget, &FlashMessageWidget::dismissed);
    ASSERT_TRUE(spy.isValid());

    // Use a very short duration so the timer fires quickly
    widget.showMessage("Auto dismiss", FlashMessageType::Info, 100);
    EXPECT_TRUE(widget.isVisible());

    // Wait for dismiss timer (100ms) + fade animation (300ms) + buffer
    processEvents(600);
    EXPECT_GE(spy.count(), 1);
    EXPECT_FALSE(widget.isVisible());
}

// ============================================================================
// Edge Case Tests
// ============================================================================

TEST_F(FlashMessageTest, EmptyMessageDoesNotCrash) {
    FlashMessageWidget widget;
    EXPECT_NO_THROW({
        widget.showMessage("");
    });
    EXPECT_TRUE(widget.isVisible());
}

TEST_F(FlashMessageTest, ShowMessageTwiceReplacesContent) {
    FlashMessageWidget widget;
    widget.showMessage("First");

    QLabel* label = widget.findChild<QLabel*>();
    ASSERT_NE(label, nullptr);
    EXPECT_EQ(label->text(), QString("First"));

    widget.showMessage("Second");
    EXPECT_EQ(label->text(), QString("Second"));
    EXPECT_TRUE(widget.isVisible());
}

TEST_F(FlashMessageTest, ShowMessageResetsOpacityToOne) {
    FlashMessageWidget widget;
    widget.setOpacity(0.3);
    widget.showMessage("Reset opacity");
    EXPECT_DOUBLE_EQ(widget.opacity(), 1.0);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
