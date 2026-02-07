#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QThread>
#include <QMutex>

namespace jules {

/// Background worker that recursively indexes filenames from repository folders.
class FilenameIndexWorker : public QObject {
    Q_OBJECT

public:
    explicit FilenameIndexWorker(QObject* parent = nullptr);

public slots:
    void scan(const QStringList& folders);

signals:
    void finished(const QStringList& indexedPaths, int fileCount);

private:
    bool shouldSkipDirectory(const QString& dirName) const;
};

/// Provides file path suggestions for new session dialogs by watching
/// repository folders and maintaining a sorted, prefix-searchable index.
class FilenameAutocompleteManager : public QObject {
    Q_OBJECT

public:
    explicit FilenameAutocompleteManager(QObject* parent = nullptr);
    ~FilenameAutocompleteManager() override;

    /// Update the set of watched repository folders and trigger re-index.
    void setRepositoryFolders(const QStringList& folders);

    /// Manually trigger a full re-scan of all watched folders.
    void refresh();

    /// Return up to @p maxResults filenames matching @p prefix (synchronous).
    QStringList suggest(const QString& prefix, int maxResults = 3) const;

    /// Number of files currently in the index.
    int indexedFileCount() const;

    /// True while a background scan is in progress.
    bool isIndexing() const;

signals:
    /// Emitted when a background scan finishes.
    void indexingComplete(int fileCount);

    /// Emitted asynchronously with suggestions (for debounced queries).
    void suggestionsReady(const QStringList& suggestions);

public slots:
    /// Request suggestions with a 100ms debounce. Results arrive via suggestionsReady().
    void requestSuggestions(const QString& prefix, int maxResults = 3);

private slots:
    void onDirectoryChanged(const QString& path);
    void onDebouncedRefresh();
    void onScanFinished(const QStringList& indexedPaths, int fileCount);
    void onDebouncedSuggest();

private:
    void startScan();

    QStringList m_folders;
    QStringList m_index; // sorted list of relative paths
    int m_fileCount = 0;
    bool m_indexing = false;

    QFileSystemWatcher m_watcher;
    QTimer m_refreshDebounce;
    QTimer m_suggestDebounce;

    QString m_pendingSuggestPrefix;
    int m_pendingSuggestMax = 3;

    QThread m_workerThread;
    FilenameIndexWorker* m_worker = nullptr;

    mutable QMutex m_indexMutex;
};

} // namespace jules
