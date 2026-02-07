#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QListWidget>
#include <QLineEdit>

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

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
