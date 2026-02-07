/**
 * @file command_palette_test.cpp
 * @brief Unit tests for CommandPalette widget
 *
 * Tests the command palette's public interface:
 * - Show/hide behavior
 * - Default actions (New Session, Settings, Refresh)
 * - Session search and fuzzy matching
 * - Keyboard navigation (Escape closes)
 * - Signal emission on action activation
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QListWidget>
#include <QLineEdit>
#include <QKeyEvent>
#include <QTest>

#include "ui/command_palette.h"

namespace jules {
namespace test {

class CommandPaletteTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_parent = new QWidget();
        m_parent->resize(800, 600);
        m_parent->show();
        m_palette = new CommandPalette(m_parent);
    }

    void TearDown() override {
        delete m_parent; // deletes m_palette too (child widget)
    }

    QLineEdit* searchInput() {
        return m_palette->findChild<QLineEdit*>();
    }

    QListWidget* resultList() {
        return m_palette->findChild<QListWidget*>();
    }

    QWidget* m_parent = nullptr;
    CommandPalette* m_palette = nullptr;
};

// ============================================================================
// Show / Hide
// ============================================================================

TEST_F(CommandPaletteTest, StartsHidden) {
    EXPECT_FALSE(m_palette->isVisible());
}

TEST_F(CommandPaletteTest, ShowPaletteMakesVisible) {
    m_palette->showPalette();
    EXPECT_TRUE(m_palette->isVisible());
}

TEST_F(CommandPaletteTest, HidePaletteMakesInvisible) {
    m_palette->showPalette();
    EXPECT_TRUE(m_palette->isVisible());

    m_palette->hidePalette();
    EXPECT_FALSE(m_palette->isVisible());
}

TEST_F(CommandPaletteTest, ShowPaletteClearsSearchInput) {
    auto* input = searchInput();
    ASSERT_NE(input, nullptr);

    // Type something, then show palette - should be cleared
    input->setText("some text");
    m_palette->showPalette();
    EXPECT_TRUE(input->text().isEmpty());
}

// ============================================================================
// Default Actions
// ============================================================================

TEST_F(CommandPaletteTest, ShowsDefaultActionsOnOpen) {
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    // Should have 3 default actions: New Session, Open Settings, Refresh Sessions
    EXPECT_EQ(list->count(), 3);
}

TEST_F(CommandPaletteTest, DefaultActionsHaveCorrectLabels) {
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);
    ASSERT_GE(list->count(), 3);

    QStringList labels;
    for (int i = 0; i < list->count(); ++i) {
        labels.append(list->item(i)->text());
    }

    EXPECT_TRUE(labels.contains("New Session"));
    EXPECT_TRUE(labels.contains("Open Settings"));
    EXPECT_TRUE(labels.contains("Refresh Sessions"));
}

TEST_F(CommandPaletteTest, FirstItemIsSelectedByDefault) {
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);
    EXPECT_EQ(list->currentRow(), 0);
}

// ============================================================================
// Session Search
// ============================================================================

TEST_F(CommandPaletteTest, SetSessionsStoresData) {
    QList<QPair<QString,QString>> sessions = {
        {"s1", "Fix authentication bug"},
        {"s2", "Add dark mode support"},
        {"s3", "Refactor database layer"}
    };
    m_palette->setSessions(sessions);

    // Sessions don't appear until user types a filter
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    // Only default actions shown (no filter typed)
    EXPECT_EQ(list->count(), 3);
}

TEST_F(CommandPaletteTest, FilterShowsMatchingSessions) {
    QList<QPair<QString,QString>> sessions = {
        {"s1", "Fix authentication bug"},
        {"s2", "Add dark mode support"},
        {"s3", "Refactor database layer"}
    };
    m_palette->setSessions(sessions);
    m_palette->showPalette();

    auto* input = searchInput();
    ASSERT_NE(input, nullptr);

    // Type a filter that matches one session
    input->setText("dark");

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    // Should show matching default actions + matching sessions
    bool foundSession = false;
    for (int i = 0; i < list->count(); ++i) {
        if (list->item(i)->text().contains("dark mode")) {
            foundSession = true;
            break;
        }
    }
    EXPECT_TRUE(foundSession) << "Session 'dark mode support' should appear in results";
}

TEST_F(CommandPaletteTest, FilterNarrowsResults) {
    m_palette->showPalette();

    auto* input = searchInput();
    auto* list = resultList();
    ASSERT_NE(input, nullptr);
    ASSERT_NE(list, nullptr);

    int defaultCount = list->count();

    // Type something that doesn't match any default action
    input->setText("zzzznothing");

    EXPECT_LT(list->count(), defaultCount);
}

// ============================================================================
// Keyboard Navigation
// ============================================================================

TEST_F(CommandPaletteTest, EscapeClosesPalette) {
    m_palette->showPalette();
    EXPECT_TRUE(m_palette->isVisible());

    QKeyEvent escEvent(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
    QApplication::sendEvent(m_palette, &escEvent);

    EXPECT_FALSE(m_palette->isVisible());
}

TEST_F(CommandPaletteTest, DownArrowMovesSelection) {
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);
    ASSERT_GE(list->count(), 2);
    EXPECT_EQ(list->currentRow(), 0);

    QKeyEvent downEvent(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
    QApplication::sendEvent(m_palette, &downEvent);

    EXPECT_EQ(list->currentRow(), 1);
}

TEST_F(CommandPaletteTest, UpArrowMovesSelectionUp) {
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);
    ASSERT_GE(list->count(), 2);

    // Move down first
    QKeyEvent downEvent(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
    QApplication::sendEvent(m_palette, &downEvent);
    EXPECT_EQ(list->currentRow(), 1);

    // Move back up
    QKeyEvent upEvent(QEvent::KeyPress, Qt::Key_Up, Qt::NoModifier);
    QApplication::sendEvent(m_palette, &upEvent);
    EXPECT_EQ(list->currentRow(), 0);
}

TEST_F(CommandPaletteTest, UpArrowDoesNotGoBelowZero) {
    m_palette->showPalette();

    auto* list = resultList();
    ASSERT_NE(list, nullptr);
    EXPECT_EQ(list->currentRow(), 0);

    QKeyEvent upEvent(QEvent::KeyPress, Qt::Key_Up, Qt::NoModifier);
    QApplication::sendEvent(m_palette, &upEvent);

    EXPECT_EQ(list->currentRow(), 0);
}

// ============================================================================
// Signals
// ============================================================================

TEST_F(CommandPaletteTest, NewSessionSignalEmitted) {
    m_palette->showPalette();

    QSignalSpy spy(m_palette, &CommandPalette::newSessionRequested);

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    // Find and click the "New Session" item
    for (int i = 0; i < list->count(); ++i) {
        if (list->item(i)->text() == "New Session") {
            list->setCurrentRow(i);
            emit list->itemActivated(list->item(i));
            break;
        }
    }

    EXPECT_EQ(spy.count(), 1);
    EXPECT_FALSE(m_palette->isVisible()); // Should auto-hide after action
}

TEST_F(CommandPaletteTest, SettingsSignalEmitted) {
    m_palette->showPalette();

    QSignalSpy spy(m_palette, &CommandPalette::settingsRequested);

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    for (int i = 0; i < list->count(); ++i) {
        if (list->item(i)->text() == "Open Settings") {
            emit list->itemActivated(list->item(i));
            break;
        }
    }

    EXPECT_EQ(spy.count(), 1);
}

TEST_F(CommandPaletteTest, RefreshSignalEmitted) {
    m_palette->showPalette();

    QSignalSpy spy(m_palette, &CommandPalette::refreshRequested);

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    for (int i = 0; i < list->count(); ++i) {
        if (list->item(i)->text() == "Refresh Sessions") {
            emit list->itemActivated(list->item(i));
            break;
        }
    }

    EXPECT_EQ(spy.count(), 1);
}

TEST_F(CommandPaletteTest, GotoSessionSignalEmitted) {
    QList<QPair<QString,QString>> sessions = {
        {"session-123", "Fix the auth bug"}
    };
    m_palette->setSessions(sessions);
    m_palette->showPalette();

    QSignalSpy spy(m_palette, &CommandPalette::actionTriggered);

    auto* input = searchInput();
    ASSERT_NE(input, nullptr);
    input->setText("auth");

    auto* list = resultList();
    ASSERT_NE(list, nullptr);

    // Find the session item (prefixed with "Go to: ")
    for (int i = 0; i < list->count(); ++i) {
        if (list->item(i)->text().contains("Fix the auth bug")) {
            emit list->itemActivated(list->item(i));
            break;
        }
    }

    ASSERT_EQ(spy.count(), 1);
    EXPECT_EQ(spy.at(0).at(0).toString(), QString("goto_session"));
    EXPECT_EQ(spy.at(0).at(1).toString(), QString("session-123"));
}

// ============================================================================
// Click Outside
// ============================================================================

TEST_F(CommandPaletteTest, ClickOutsideContainerClosesPalette) {
    m_palette->showPalette();
    EXPECT_TRUE(m_palette->isVisible());

    // Simulate a click on the overlay (outside the container)
    QMouseEvent clickEvent(QEvent::MouseButtonPress, QPointF(5, 5),
                           QPointF(5, 5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QApplication::sendEvent(m_palette, &clickEvent);

    EXPECT_FALSE(m_palette->isVisible());
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinuxTest");
    QCoreApplication::setApplicationName("CommandPaletteTest");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
