#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QPushButton>
#include <QListWidget>
#include <QTimer>
#include <QEventLoop>

#include "ui/merge_conflict_dialog.h"

namespace jules {
namespace test {

class MergeConflictDialogTest : public ::testing::Test {
protected:
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    ConflictFile makeConflictFile(const QString& path) {
        ConflictFile file;
        file.path = path;
        file.language = "cpp";
        file.originalContent =
            "line1\n"
            "<<<<<<< HEAD\n"
            "our change\n"
            "=======\n"
            "their change\n"
            ">>>>>>> feature-branch\n"
            "line4\n";
        return file;
    }

    ConflictFile makeTwoConflictFile(const QString& path) {
        ConflictFile file;
        file.path = path;
        file.language = "cpp";
        file.originalContent =
            "line1\n"
            "<<<<<<< HEAD\n"
            "our first\n"
            "=======\n"
            "their first\n"
            ">>>>>>> feature-branch\n"
            "middle\n"
            "<<<<<<< HEAD\n"
            "our second\n"
            "=======\n"
            "their second\n"
            ">>>>>>> feature-branch\n"
            "end\n";
        return file;
    }
};

// ============================================================================
// Data Struct Tests
// ============================================================================

TEST_F(MergeConflictDialogTest, ConflictRegionDefaultResolutionIsNone) {
    ConflictRegion region;
    EXPECT_EQ(region.resolution, ConflictRegion::Resolution::None);
    EXPECT_FALSE(region.resolved);
}

TEST_F(MergeConflictDialogTest, ConflictFileAllResolvedEmptyReturnsFalse) {
    ConflictFile file;
    file.path = "test.cpp";
    // No conflicts at all - allResolved returns false (requires non-empty)
    EXPECT_FALSE(file.allResolved());
}

TEST_F(MergeConflictDialogTest, ConflictFileWithUnresolvedConflict) {
    ConflictFile file;
    file.path = "test.cpp";
    ConflictRegion region;
    region.startLine = 1;
    region.endLine = 5;
    region.oursContent = "ours";
    region.theirsContent = "theirs";
    region.resolved = false;
    file.conflicts.push_back(region);
    EXPECT_FALSE(file.allResolved());
}

TEST_F(MergeConflictDialogTest, ConflictFileAllResolvedWhenAllMarked) {
    ConflictFile file;
    file.path = "test.cpp";
    ConflictRegion region;
    region.startLine = 1;
    region.endLine = 5;
    region.oursContent = "ours";
    region.theirsContent = "theirs";
    region.resolved = true;
    region.resolution = ConflictRegion::Resolution::Ours;
    file.conflicts.push_back(region);
    EXPECT_TRUE(file.allResolved());
}

// ============================================================================
// Dialog Construction Tests
// ============================================================================

TEST_F(MergeConflictDialogTest, ConstructionDoesNotCrash) {
    EXPECT_NO_THROW({
        MergeConflictDialog dialog;
    });
}

TEST_F(MergeConflictDialogTest, InitialFileCountIsZero) {
    MergeConflictDialog dialog;
    EXPECT_EQ(dialog.fileCount(), 0);
}

TEST_F(MergeConflictDialogTest, InitialUnresolvedCountIsZero) {
    MergeConflictDialog dialog;
    EXPECT_EQ(dialog.unresolvedCount(), 0);
}

// ============================================================================
// Conflict Files Tests
// ============================================================================

TEST_F(MergeConflictDialogTest, SetConflictFilesUpdatesCount) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    files.push_back(makeConflictFile("src/b.cpp"));

    dialog.setConflictFiles(files);
    EXPECT_EQ(dialog.fileCount(), 2);
}

TEST_F(MergeConflictDialogTest, AddConflictFileAppends) {
    MergeConflictDialog dialog;
    dialog.addConflictFile(makeConflictFile("src/a.cpp"));
    EXPECT_EQ(dialog.fileCount(), 1);

    dialog.addConflictFile(makeConflictFile("src/b.cpp"));
    EXPECT_EQ(dialog.fileCount(), 2);
}

TEST_F(MergeConflictDialogTest, ClearResetsAll) {
    MergeConflictDialog dialog;
    dialog.addConflictFile(makeConflictFile("src/a.cpp"));
    EXPECT_EQ(dialog.fileCount(), 1);

    dialog.clear();
    EXPECT_EQ(dialog.fileCount(), 0);
    EXPECT_EQ(dialog.unresolvedCount(), 0);
}

TEST_F(MergeConflictDialogTest, ParseFindsConflictMarkers) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));

    dialog.setConflictFiles(files);

    auto resolved = dialog.getResolvedFiles();
    ASSERT_EQ(resolved.size(), 1u);
    EXPECT_EQ(resolved[0].conflicts.size(), 1u);
    EXPECT_EQ(resolved[0].conflicts[0].oursContent, QString("our change"));
    EXPECT_EQ(resolved[0].conflicts[0].theirsContent, QString("their change"));
}

TEST_F(MergeConflictDialogTest, MultipleConflictsPerFile) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeTwoConflictFile("src/multi.cpp"));

    dialog.setConflictFiles(files);

    auto resolved = dialog.getResolvedFiles();
    ASSERT_EQ(resolved.size(), 1u);
    EXPECT_EQ(resolved[0].conflicts.size(), 2u);
    EXPECT_EQ(dialog.unresolvedCount(), 2);
}

// ============================================================================
// Resolution Tests
// ============================================================================

TEST_F(MergeConflictDialogTest, AcceptOursResolvesConflict) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    dialog.setConflictFiles(files);
    processEvents();

    // setConflictFiles auto-selects file 0 and conflict 0
    // Find and click the "Accept Ours" button
    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* oursBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Ours")) {
            oursBtn = btn;
            break;
        }
    }
    ASSERT_NE(oursBtn, nullptr);
    oursBtn->click();
    processEvents();

    EXPECT_TRUE(dialog.allResolved());
    auto resolved = dialog.getResolvedFiles();
    ASSERT_EQ(resolved.size(), 1u);
    EXPECT_TRUE(resolved[0].conflicts[0].resolved);
    EXPECT_EQ(resolved[0].conflicts[0].resolution, ConflictRegion::Resolution::Ours);
}

TEST_F(MergeConflictDialogTest, ConflictResolvedSignalEmitted) {
    MergeConflictDialog dialog;
    QSignalSpy spy(&dialog, &MergeConflictDialog::conflictResolved);
    ASSERT_TRUE(spy.isValid());

    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    dialog.setConflictFiles(files);
    processEvents();

    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* theirsBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Theirs")) {
            theirsBtn = btn;
            break;
        }
    }
    ASSERT_NE(theirsBtn, nullptr);
    theirsBtn->click();
    processEvents();

    EXPECT_GE(spy.count(), 1);
    EXPECT_EQ(spy.at(0).at(0).toString(), QString("src/a.cpp"));
}

TEST_F(MergeConflictDialogTest, AllConflictsResolvedSignalWhenAllDone) {
    MergeConflictDialog dialog;
    QSignalSpy spy(&dialog, &MergeConflictDialog::allConflictsResolved);
    ASSERT_TRUE(spy.isValid());

    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    dialog.setConflictFiles(files);
    processEvents();

    // Accept ours to resolve the single conflict
    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* oursBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Ours")) {
            oursBtn = btn;
            break;
        }
    }
    ASSERT_NE(oursBtn, nullptr);
    oursBtn->click();
    processEvents();

    EXPECT_GE(spy.count(), 1);
}

TEST_F(MergeConflictDialogTest, AllResolvedReturnsTrueAfterResolving) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    dialog.setConflictFiles(files);
    processEvents();

    EXPECT_FALSE(dialog.allResolved());

    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* bothBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Both")) {
            bothBtn = btn;
            break;
        }
    }
    ASSERT_NE(bothBtn, nullptr);
    bothBtn->click();
    processEvents();

    EXPECT_TRUE(dialog.allResolved());
}

// ============================================================================
// Merge Flow Tests
// ============================================================================

TEST_F(MergeConflictDialogTest, MergeCompletedSignalIsValid) {
    MergeConflictDialog dialog;
    QSignalSpy spy(&dialog, &MergeConflictDialog::mergeCompleted);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(MergeConflictDialogTest, MergeCancelledOnCancel) {
    MergeConflictDialog dialog;
    QSignalSpy spy(&dialog, &MergeConflictDialog::mergeCancelled);
    ASSERT_TRUE(spy.isValid());

    // Find the cancel button
    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* cancelBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Cancel")) {
            cancelBtn = btn;
            break;
        }
    }
    ASSERT_NE(cancelBtn, nullptr);
    cancelBtn->click();
    processEvents();

    EXPECT_EQ(spy.count(), 1);
}

TEST_F(MergeConflictDialogTest, CompleteRequiresAllResolved) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    dialog.setConflictFiles(files);
    processEvents();

    // Find the complete button - should be disabled when not all resolved
    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* completeBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Complete")) {
            completeBtn = btn;
            break;
        }
    }
    ASSERT_NE(completeBtn, nullptr);
    EXPECT_FALSE(completeBtn->isEnabled());
}

TEST_F(MergeConflictDialogTest, GetResolvedFilesReturnsData) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    files.push_back(makeConflictFile("src/b.cpp"));
    dialog.setConflictFiles(files);

    auto resolved = dialog.getResolvedFiles();
    EXPECT_EQ(resolved.size(), 2u);
    EXPECT_EQ(resolved[0].path, QString("src/a.cpp"));
    EXPECT_EQ(resolved[1].path, QString("src/b.cpp"));
}

TEST_F(MergeConflictDialogTest, CompleteBtnEnabledAfterAllResolved) {
    MergeConflictDialog dialog;
    std::vector<ConflictFile> files;
    files.push_back(makeConflictFile("src/a.cpp"));
    dialog.setConflictFiles(files);
    processEvents();

    // Resolve the conflict
    auto buttons = dialog.findChildren<QPushButton*>();
    QPushButton* oursBtn = nullptr;
    QPushButton* completeBtn = nullptr;
    for (auto* btn : buttons) {
        if (btn->text().contains("Ours")) oursBtn = btn;
        if (btn->text().contains("Complete")) completeBtn = btn;
    }
    ASSERT_NE(oursBtn, nullptr);
    ASSERT_NE(completeBtn, nullptr);

    EXPECT_FALSE(completeBtn->isEnabled());
    oursBtn->click();
    processEvents();

    EXPECT_TRUE(completeBtn->isEnabled());
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
