#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QListWidget>
#include <QLineEdit>
#include <QScreen>
#include <QGuiApplication>

#include "ui/tray_popup_widget.h"

namespace jules {
namespace test {

class TrayPopupWidgetTest : public ::testing::Test {
protected:
};

TEST_F(TrayPopupWidgetTest, CanConstructWithNullRepo) {
    TrayPopupWidget widget(nullptr);
    SUCCEED();
}

TEST_F(TrayPopupWidgetTest, CanConstructWithParent) {
    QWidget parent;
    TrayPopupWidget widget(nullptr, &parent);
    EXPECT_EQ(widget.parentWidget(), &parent);
}

TEST_F(TrayPopupWidgetTest, SessionSelectedSignalIsValid) {
    TrayPopupWidget widget(nullptr);
    QSignalSpy spy(&widget, &TrayPopupWidget::sessionSelected);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(TrayPopupWidgetTest, SettingsRequestedSignalIsValid) {
    TrayPopupWidget widget(nullptr);
    QSignalSpy spy(&widget, &TrayPopupWidget::settingsRequested);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(TrayPopupWidgetTest, QuitRequestedSignalIsValid) {
    TrayPopupWidget widget(nullptr);
    QSignalSpy spy(&widget, &TrayPopupWidget::quitRequested);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(TrayPopupWidgetTest, NewSessionRequestedSignalIsValid) {
    TrayPopupWidget widget(nullptr);
    QSignalSpy spy(&widget, &TrayPopupWidget::newSessionRequested);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(TrayPopupWidgetTest, RefreshSessionsDoesNotCrash) {
    TrayPopupWidget widget(nullptr);
    EXPECT_NO_THROW(widget.refreshSessions());
}

TEST_F(TrayPopupWidgetTest, InitialOpacity) {
    TrayPopupWidget widget(nullptr);
    // Constructor sets m_opacity to 0.0
    EXPECT_DOUBLE_EQ(widget.popupOpacity(), 0.0);
}

TEST_F(TrayPopupWidgetTest, SetPopupOpacity) {
    TrayPopupWidget widget(nullptr);
    widget.setPopupOpacity(0.5);
    EXPECT_DOUBLE_EQ(widget.popupOpacity(), 0.5);
}

TEST_F(TrayPopupWidgetTest, HasSessionList) {
    TrayPopupWidget widget(nullptr);
    auto* list = widget.findChild<QListWidget*>();
    EXPECT_NE(list, nullptr);
}

TEST_F(TrayPopupWidgetTest, HasPromptInput) {
    TrayPopupWidget widget(nullptr);
    auto* input = widget.findChild<QLineEdit*>();
    EXPECT_NE(input, nullptr);
}

// ============================================================================
// Popup Window Flags Tests
// ============================================================================

TEST_F(TrayPopupWidgetTest, HasPopupWindowFlag) {
    TrayPopupWidget widget(nullptr);
    // Must use Qt::Popup for Wayland compatibility (Qt::Window ignores move())
    EXPECT_TRUE(widget.windowFlags() & Qt::Popup);
}

TEST_F(TrayPopupWidgetTest, HasFramelessWindowHint) {
    TrayPopupWidget widget(nullptr);
    EXPECT_TRUE(widget.windowFlags() & Qt::FramelessWindowHint);
}

TEST_F(TrayPopupWidgetTest, HasTranslucentBackground) {
    TrayPopupWidget widget(nullptr);
    EXPECT_TRUE(widget.testAttribute(Qt::WA_TranslucentBackground));
}

// ============================================================================
// Popup Size Tests
// ============================================================================

TEST_F(TrayPopupWidgetTest, HasExpectedFixedSize) {
    TrayPopupWidget widget(nullptr);
    // POPUP_WIDTH=400, POPUP_HEIGHT=650 (from header constants)
    EXPECT_EQ(widget.width(), 400);
    EXPECT_EQ(widget.height(), 650);
}

// ============================================================================
// Popup Positioning Tests
//
// positionOnScreen is private, but showNearPosition() calls it and then
// positions the widget. We test observable positioning results.
// ============================================================================

TEST_F(TrayPopupWidgetTest, ShowNearPositionClampsToScreen) {
    // Test that showing at extreme coordinates doesn't place popup off-screen
    TrayPopupWidget widget(nullptr);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        GTEST_SKIP() << "No screen available";
    }

    QRect avail = screen->availableGeometry();

    // Show near bottom-right corner (typical tray position)
    widget.showNearPosition(QPoint(avail.right(), avail.bottom()));

    // Widget geometry should be within screen bounds
    QRect geom = widget.geometry();
    EXPECT_GE(geom.left(), avail.left());
    EXPECT_LE(geom.right(), avail.right());
    EXPECT_GE(geom.top(), avail.top());
    EXPECT_LE(geom.bottom(), avail.bottom());

    widget.hide();
}

TEST_F(TrayPopupWidgetTest, ShowNearPositionHandlesTopLeftCorner) {
    TrayPopupWidget widget(nullptr);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        GTEST_SKIP() << "No screen available";
    }

    QRect avail = screen->availableGeometry();

    // Show near top-left (unusual but valid)
    widget.showNearPosition(QPoint(avail.left(), avail.top()));

    QRect geom = widget.geometry();
    EXPECT_GE(geom.left(), avail.left());
    EXPECT_GE(geom.top(), avail.top());
    EXPECT_LE(geom.right(), avail.right());
    EXPECT_LE(geom.bottom(), avail.bottom());

    widget.hide();
}

TEST_F(TrayPopupWidgetTest, ShowNearPositionHandlesOriginZero) {
    // Simulates Wayland's QCursor::pos() returning (0,0)
    TrayPopupWidget widget(nullptr);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        GTEST_SKIP() << "No screen available";
    }

    QRect avail = screen->availableGeometry();

    // QCursor returns (0,0) on Wayland — positionOnScreen treats this as unreliable
    widget.showNearPosition(QPoint(0, 0));

    QRect geom = widget.geometry();
    // Even with (0,0), popup should be within screen bounds
    EXPECT_GE(geom.left(), avail.left());
    EXPECT_GE(geom.top(), avail.top());
    EXPECT_LE(geom.right(), avail.right());
    EXPECT_LE(geom.bottom(), avail.bottom());

    widget.hide();
}

TEST_F(TrayPopupWidgetTest, ShowNearPositionHandlesNegativeCoords) {
    TrayPopupWidget widget(nullptr);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        GTEST_SKIP() << "No screen available";
    }

    QRect avail = screen->availableGeometry();

    // Negative coordinates (garbage input)
    widget.showNearPosition(QPoint(-100, -100));

    QRect geom = widget.geometry();
    EXPECT_GE(geom.left(), avail.left());
    EXPECT_GE(geom.top(), avail.top());

    widget.hide();
}

TEST_F(TrayPopupWidgetTest, ShowNearPositionWithParentWidget) {
    // On Wayland, popup requires a visible parent surface
    QWidget parent;
    parent.resize(800, 600);
    TrayPopupWidget widget(nullptr, &parent);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        GTEST_SKIP() << "No screen available";
    }

    QRect avail = screen->availableGeometry();

    // Show with a parent — should not crash even if parent is not visible
    EXPECT_NO_THROW(widget.showNearPosition(QPoint(avail.center())));

    widget.hide();
    parent.hide();
}

TEST_F(TrayPopupWidgetTest, MultipleShowHideCycles) {
    // Regression: ensure repeated show/hide doesn't crash or leak
    TrayPopupWidget widget(nullptr);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        GTEST_SKIP() << "No screen available";
    }

    QRect avail = screen->availableGeometry();
    QPoint pos(avail.right() - 50, avail.bottom() - 50);

    for (int i = 0; i < 5; ++i) {
        EXPECT_NO_THROW(widget.showNearPosition(pos));
        widget.hide();
    }
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
