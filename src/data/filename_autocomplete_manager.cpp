#include "data/filename_autocomplete_manager.h"

#include <QDirIterator>
#include <QDir>
#include <QFileInfo>
#include <QDebug>

#include <algorithm>

namespace jules {

// ============================================================================
// FilenameIndexWorker
// ============================================================================

FilenameIndexWorker::FilenameIndexWorker(QObject* parent)
    : QObject(parent)
{
}

void FilenameIndexWorker::scan(const QStringList& folders)
{
    QStringList allPaths;

    for (const QString& folder : folders) {
        QDir baseDir(folder);
        if (!baseDir.exists()) {
            qDebug() << "[FilenameIndexWorker] Skipping non-existent folder:" << folder;
            continue;
        }

        QString basePath = baseDir.absolutePath();
        QDirIterator it(basePath, QDir::Files, QDirIterator::Subdirectories);

        while (it.hasNext()) {
            it.next();

            // Check if any parent directory should be skipped
            QString relativePath = it.filePath().mid(basePath.length() + 1);
            bool skip = false;
            const QStringList parts = relativePath.split('/');
            for (int i = 0; i < parts.size() - 1; ++i) {
                if (shouldSkipDirectory(parts[i])) {
                    skip = true;
                    break;
                }
            }
            if (skip) {
                continue;
            }

            allPaths.append(relativePath);
        }
    }

    std::sort(allPaths.begin(), allPaths.end(),
              [](const QString& a, const QString& b) {
                  return a.compare(b, Qt::CaseInsensitive) < 0;
              });
    int count = allPaths.size();
    qDebug() << "[FilenameIndexWorker] Scan complete:" << count << "files indexed from" << folders.size() << "folders";
    emit finished(allPaths, count);
}

bool FilenameIndexWorker::shouldSkipDirectory(const QString& dirName) const
{
    if (dirName.startsWith('.')) {
        return true;
    }

    static const QStringList skipList = {
        "node_modules", "build", "__pycache__", "dist", ".git",
        "target", "vendor", "venv", ".venv", "env",
        "cmake-build-debug", "cmake-build-release"
    };

    return skipList.contains(dirName, Qt::CaseInsensitive);
}

// ============================================================================
// FilenameAutocompleteManager
// ============================================================================

FilenameAutocompleteManager::FilenameAutocompleteManager(QObject* parent)
    : QObject(parent)
    , m_worker(new FilenameIndexWorker)  // no parent - moved to thread
{
    // Setup debounce timers
    m_refreshDebounce.setSingleShot(true);
    m_refreshDebounce.setInterval(500);
    connect(&m_refreshDebounce, &QTimer::timeout, this, &FilenameAutocompleteManager::onDebouncedRefresh);

    m_suggestDebounce.setSingleShot(true);
    m_suggestDebounce.setInterval(100);
    connect(&m_suggestDebounce, &QTimer::timeout, this, &FilenameAutocompleteManager::onDebouncedSuggest);

    // Setup file system watcher
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged,
            this, &FilenameAutocompleteManager::onDirectoryChanged);

    // Setup worker thread
    m_worker->moveToThread(&m_workerThread);
    connect(&m_workerThread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(this, &FilenameAutocompleteManager::indexingComplete,
            this, []() {}, Qt::QueuedConnection); // placeholder
    connect(m_worker, &FilenameIndexWorker::finished,
            this, &FilenameAutocompleteManager::onScanFinished, Qt::QueuedConnection);

    m_workerThread.start();
}

FilenameAutocompleteManager::~FilenameAutocompleteManager()
{
    m_workerThread.quit();
    m_workerThread.wait(3000);
}

void FilenameAutocompleteManager::setRepositoryFolders(const QStringList& folders)
{
    if (m_folders == folders) {
        return;
    }

    // Remove old watches
    QStringList watched = m_watcher.directories();
    if (!watched.isEmpty()) {
        m_watcher.removePaths(watched);
    }

    m_folders = folders;

    // Add new watches (top-level only to avoid excessive watchers)
    for (const QString& folder : m_folders) {
        if (QDir(folder).exists()) {
            m_watcher.addPath(folder);
        }
    }

    qDebug() << "[FilenameAutocomplete] Repository folders set:" << m_folders.size() << "folders";
    startScan();
}

void FilenameAutocompleteManager::refresh()
{
    qDebug() << "[FilenameAutocomplete] Manual refresh requested";
    startScan();
}

QStringList FilenameAutocompleteManager::suggest(const QString& prefix, int maxResults) const
{
    if (prefix.isEmpty()) {
        return {};
    }

    QMutexLocker locker(&m_indexMutex);

    QStringList results;
    QString lowerPrefix = prefix.toLower();

    // Binary search for first match (sorted case-insensitively)
    auto it = std::lower_bound(m_index.cbegin(), m_index.cend(), lowerPrefix,
        [](const QString& path, const QString& value) {
            return path.toLower() < value;
        });

    // Collect matches from the position found
    while (it != m_index.cend() && results.size() < maxResults) {
        if (it->toLower().startsWith(lowerPrefix)) {
            results.append(*it);
        } else {
            break;
        }
        ++it;
    }

    // If binary search didn't find enough, also check for substring matches
    // (filename contains prefix, not just path starts with prefix)
    if (results.size() < maxResults) {
        for (const QString& path : m_index) {
            if (results.size() >= maxResults) {
                break;
            }
            // Check if filename (last component) starts with prefix
            int lastSlash = path.lastIndexOf('/');
            QString filename = (lastSlash >= 0) ? path.mid(lastSlash + 1) : path;
            if (filename.toLower().startsWith(lowerPrefix) && !results.contains(path)) {
                results.append(path);
            }
        }
    }

    return results;
}

int FilenameAutocompleteManager::indexedFileCount() const
{
    QMutexLocker locker(&m_indexMutex);
    return m_fileCount;
}

bool FilenameAutocompleteManager::isIndexing() const
{
    return m_indexing;
}

void FilenameAutocompleteManager::requestSuggestions(const QString& prefix, int maxResults)
{
    m_pendingSuggestPrefix = prefix;
    m_pendingSuggestMax = maxResults;
    m_suggestDebounce.start();
}

void FilenameAutocompleteManager::onDirectoryChanged(const QString& path)
{
    Q_UNUSED(path)
    // Debounce: filesystem changes often come in bursts
    m_refreshDebounce.start();
}

void FilenameAutocompleteManager::onDebouncedRefresh()
{
    qDebug() << "[FilenameAutocomplete] Filesystem change detected, re-indexing";
    startScan();
}

void FilenameAutocompleteManager::onScanFinished(const QStringList& indexedPaths, int fileCount)
{
    {
        QMutexLocker locker(&m_indexMutex);
        m_index = indexedPaths;
        m_fileCount = fileCount;
    }
    m_indexing = false;
    qDebug() << "[FilenameAutocomplete] Index updated:" << fileCount << "files";
    emit indexingComplete(fileCount);
}

void FilenameAutocompleteManager::onDebouncedSuggest()
{
    QStringList results = suggest(m_pendingSuggestPrefix, m_pendingSuggestMax);
    emit suggestionsReady(results);
}

void FilenameAutocompleteManager::startScan()
{
    if (m_folders.isEmpty()) {
        QMutexLocker locker(&m_indexMutex);
        m_index.clear();
        m_fileCount = 0;
        m_indexing = false;
        emit indexingComplete(0);
        return;
    }

    m_indexing = true;
    qDebug() << "[FilenameAutocomplete] Starting background scan of" << m_folders.size() << "folders";
    QMetaObject::invokeMethod(m_worker, "scan", Qt::QueuedConnection,
                              Q_ARG(QStringList, m_folders));
}

} // namespace jules
