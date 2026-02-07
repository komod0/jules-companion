#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QThread>

#include "data/filename_autocomplete_manager.h"

namespace jules {
namespace test {

class FilenameAutocompleteTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_tempDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(m_tempDir->isValid());
        m_manager = std::make_unique<FilenameAutocompleteManager>();
    }

    void TearDown() override {
        m_manager.reset();
        m_tempDir.reset();
    }

    /// Create a file with dummy content at the given absolute path,
    /// creating parent directories as needed.
    void createFile(const QString& path) {
        QFileInfo info(path);
        QDir().mkpath(info.absolutePath());
        QFile f(path);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("content");
        f.close();
    }

    /// Build a small directory tree inside m_tempDir and return the root path.
    /// Structure:
    ///   root/
    ///     src/main.cpp
    ///     src/utils.cpp
    ///     src/helpers/helper.cpp
    ///     include/api.h
    ///     README.md
    QString buildTestTree() {
        QString root = m_tempDir->path() + "/repo";
        createFile(root + "/src/main.cpp");
        createFile(root + "/src/utils.cpp");
        createFile(root + "/src/helpers/helper.cpp");
        createFile(root + "/include/api.h");
        createFile(root + "/README.md");
        return root;
    }

    /// Wait for indexingComplete signal with a timeout.
    bool waitForIndexing(int timeoutMs = 5000) {
        QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
        return spy.wait(timeoutMs);
    }

    std::unique_ptr<QTemporaryDir> m_tempDir;
    std::unique_ptr<FilenameAutocompleteManager> m_manager;
};

// ============================================================================
// 1. Construction
// ============================================================================

TEST_F(FilenameAutocompleteTest, ConstructionDoesNotCrash) {
    // Manager was already created in SetUp; just verify it's alive
    EXPECT_NE(m_manager.get(), nullptr);
}

TEST_F(FilenameAutocompleteTest, InitialCountIsZero) {
    EXPECT_EQ(m_manager->indexedFileCount(), 0);
}

TEST_F(FilenameAutocompleteTest, InitialNotIndexing) {
    EXPECT_FALSE(m_manager->isIndexing());
}

// ============================================================================
// 2. Indexing
// ============================================================================

TEST_F(FilenameAutocompleteTest, SetRepositoryFoldersTriggersIndexing) {
    QString root = buildTestTree();

    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    ASSERT_TRUE(spy.isValid());

    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    EXPECT_GE(spy.count(), 1);
    int fileCount = spy.last().at(0).toInt();
    EXPECT_GT(fileCount, 0);
}

TEST_F(FilenameAutocompleteTest, CorrectFileCount) {
    QString root = buildTestTree();

    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    // 5 files: main.cpp, utils.cpp, helper.cpp, api.h, README.md
    EXPECT_EQ(m_manager->indexedFileCount(), 5);
}

TEST_F(FilenameAutocompleteTest, EmptyFoldersClearsIndex) {
    QString root = buildTestTree();

    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));
    EXPECT_GT(m_manager->indexedFileCount(), 0);

    // Now clear - empty folders may or may not emit indexingComplete
    m_manager->setRepositoryFolders({});
    // Give time for any async cleanup
    QEventLoop loop;
    QTimer::singleShot(200, &loop, &QEventLoop::quit);
    loop.exec();
    EXPECT_EQ(m_manager->indexedFileCount(), 0);
}

TEST_F(FilenameAutocompleteTest, NonexistentFolderSkipped) {
    QString root = buildTestTree();
    QString badPath = m_tempDir->path() + "/does_not_exist";

    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root, badPath});
    ASSERT_TRUE(spy.wait(5000));

    // Should only have files from the valid root
    EXPECT_EQ(m_manager->indexedFileCount(), 5);
}

TEST_F(FilenameAutocompleteTest, SkipsHiddenDirectories) {
    QString root = m_tempDir->path() + "/repo";
    createFile(root + "/visible.cpp");
    createFile(root + "/.hidden/secret.cpp");
    createFile(root + "/.git/config");

    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    // Only visible.cpp should be indexed; .hidden/ and .git/ are skipped
    EXPECT_EQ(m_manager->indexedFileCount(), 1);
}

// ============================================================================
// 3. Suggest (synchronous)
// ============================================================================

TEST_F(FilenameAutocompleteTest, EmptyPrefixReturnsEmpty) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    auto results = m_manager->suggest("", 10);
    EXPECT_TRUE(results.isEmpty());
}

TEST_F(FilenameAutocompleteTest, PrefixMatchesWork) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    // "src/" should match paths starting with src/
    auto results = m_manager->suggest("src/", 10);
    EXPECT_GE(results.size(), 1);
    for (const auto& r : results) {
        EXPECT_TRUE(r.toLower().startsWith("src/"));
    }
}

TEST_F(FilenameAutocompleteTest, CaseInsensitiveSearch) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    // "readme" (lowercase) should match README.md
    auto results = m_manager->suggest("readme", 10);
    EXPECT_GE(results.size(), 1);
    bool found = false;
    for (const auto& r : results) {
        if (r.contains("README.md", Qt::CaseInsensitive)) {
            found = true;
            break;
        }
    }
    EXPECT_TRUE(found) << "Expected to find README.md with lowercase prefix 'readme'";
}

TEST_F(FilenameAutocompleteTest, MaxResultsLimit) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    // "src/" matches 3 files, but maxResults=1 should limit to 1
    auto results = m_manager->suggest("src/", 1);
    EXPECT_LE(results.size(), 1);
}

TEST_F(FilenameAutocompleteTest, FindsFilenameComponentMatches) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    // "helper" should match src/helpers/helper.cpp (filename component)
    auto results = m_manager->suggest("helper", 10);
    EXPECT_GE(results.size(), 1);
    bool found = false;
    for (const auto& r : results) {
        if (r.contains("helper.cpp")) {
            found = true;
            break;
        }
    }
    EXPECT_TRUE(found) << "Expected to find helper.cpp via filename component match";
}

// ============================================================================
// 4. Debounced (requestSuggestions)
// ============================================================================

TEST_F(FilenameAutocompleteTest, RequestSuggestionsEmitsSuggestionsReady) {
    QString root = buildTestTree();
    QSignalSpy indexSpy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(indexSpy.wait(5000));

    QSignalSpy suggestSpy(m_manager.get(), &FilenameAutocompleteManager::suggestionsReady);
    ASSERT_TRUE(suggestSpy.isValid());

    m_manager->requestSuggestions("src/", 5);
    ASSERT_TRUE(suggestSpy.wait(2000));

    EXPECT_GE(suggestSpy.count(), 1);
    auto suggestions = suggestSpy.last().at(0).toStringList();
    EXPECT_GE(suggestions.size(), 1);
}

TEST_F(FilenameAutocompleteTest, DebounceCoalescesRapidCalls) {
    QString root = buildTestTree();
    QSignalSpy indexSpy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(indexSpy.wait(5000));

    QSignalSpy suggestSpy(m_manager.get(), &FilenameAutocompleteManager::suggestionsReady);

    // Fire multiple rapid requests; debounce should coalesce them
    m_manager->requestSuggestions("s", 5);
    m_manager->requestSuggestions("sr", 5);
    m_manager->requestSuggestions("src", 5);
    m_manager->requestSuggestions("src/", 5);

    ASSERT_TRUE(suggestSpy.wait(2000));

    // Should have emitted only 1 signal (debounced), using the last prefix "src/"
    EXPECT_EQ(suggestSpy.count(), 1);
    auto suggestions = suggestSpy.last().at(0).toStringList();
    for (const auto& s : suggestions) {
        EXPECT_TRUE(s.toLower().startsWith("src/"));
    }
}

// ============================================================================
// 5. Refresh
// ============================================================================

TEST_F(FilenameAutocompleteTest, ManualRefreshTriggersRescan) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));
    int initialCount = m_manager->indexedFileCount();

    QSignalSpy spy2(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->refresh();
    ASSERT_TRUE(spy2.wait(5000));

    // File count should be the same since nothing changed on disk
    EXPECT_EQ(m_manager->indexedFileCount(), initialCount);
}

TEST_F(FilenameAutocompleteTest, RefreshAfterFileAdditionFindsNewFile) {
    QString root = buildTestTree();
    QSignalSpy spy(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root});
    ASSERT_TRUE(spy.wait(5000));

    EXPECT_EQ(m_manager->indexedFileCount(), 5);

    // Add a new file
    createFile(root + "/src/new_file.cpp");

    QSignalSpy spy2(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->refresh();
    ASSERT_TRUE(spy2.wait(5000));

    EXPECT_EQ(m_manager->indexedFileCount(), 6);
}

TEST_F(FilenameAutocompleteTest, IndexSurvivesFolderChange) {
    QString root1 = m_tempDir->path() + "/repo1";
    createFile(root1 + "/file1.cpp");

    QSignalSpy spy1(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root1});
    ASSERT_TRUE(spy1.wait(5000));
    EXPECT_EQ(m_manager->indexedFileCount(), 1);

    // Switch to a different folder
    QString root2 = m_tempDir->path() + "/repo2";
    createFile(root2 + "/a.py");
    createFile(root2 + "/b.py");
    createFile(root2 + "/c.py");

    QSignalSpy spy2(m_manager.get(), &FilenameAutocompleteManager::indexingComplete);
    m_manager->setRepositoryFolders({root2});
    ASSERT_TRUE(spy2.wait(5000));

    // Should now index the new folder only
    EXPECT_EQ(m_manager->indexedFileCount(), 3);

    // Old folder's files should not appear in suggestions
    auto results = m_manager->suggest("file1", 10);
    EXPECT_TRUE(results.isEmpty());
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
