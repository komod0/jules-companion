#include "rendering/diff_precomputation_service.h"

#include <QDebug>
#include <QMutex>
#include <QMutexLocker>
#include <QRunnable>
#include <QThreadPool>

#include <algorithm>
#include <list>
#include <map>
#include <string>

namespace jules {

namespace {

// Parse a single CachedDiff into a DiffSection
DiffSection convertDiff(const CachedDiff& cached) {
    DiffSection section;
    section.patch = cached.patch.toStdString();
    section.language = cached.language.value_or(QString()).toStdString();
    section.filename = cached.filename.value_or(QString()).toStdString();
    return section;
}

} // namespace

class DiffPrecomputationService::Impl {
public:
    explicit Impl(DiffPrecomputationService* owner)
        : m_owner(owner)
        , m_maxSessions(10)
    {
    }

    void precomputeAll(const QString& sessionId, const QList<CachedDiff>& diffs) {
        // Capture diffs by value for the runnable
        auto* runnable = new PrecomputeRunnable(this, sessionId, diffs);
        runnable->setAutoDelete(true);
        QThreadPool::globalInstance()->start(runnable);
    }

    std::optional<std::vector<DiffSection>> getPrecomputed(const QString& sessionId) {
        QMutexLocker lock(&m_mutex);
        auto it = m_cache.find(sessionId);
        if (it == m_cache.end()) {
            return std::nullopt;
        }
        // Touch LRU
        m_lruList.splice(m_lruList.begin(), m_lruList, it->second.lruIt);
        return it->second.sections;
    }

    bool hasPrecomputed(const QString& sessionId) {
        QMutexLocker lock(&m_mutex);
        return m_cache.find(sessionId) != m_cache.end();
    }

    void invalidate(const QString& sessionId) {
        QMutexLocker lock(&m_mutex);
        auto it = m_cache.find(sessionId);
        if (it != m_cache.end()) {
            m_lruList.erase(it->second.lruIt);
            m_cache.erase(it);
        }
    }

    void clear() {
        QMutexLocker lock(&m_mutex);
        m_cache.clear();
        m_lruList.clear();
    }

    void setCacheCapacity(int sessions) {
        QMutexLocker lock(&m_mutex);
        m_maxSessions = std::max(1, sessions);
        while (static_cast<int>(m_cache.size()) > m_maxSessions) {
            evictOneLocked();
        }
    }

private:
    struct CacheEntry {
        std::vector<DiffSection> sections;
        std::list<QString>::iterator lruIt;
    };

    class PrecomputeRunnable : public QRunnable {
    public:
        PrecomputeRunnable(Impl* impl, const QString& sessionId, const QList<CachedDiff>& diffs)
            : m_impl(impl)
            , m_sessionId(sessionId)
            , m_diffs(diffs)
        {
        }

        void run() override {
            std::vector<DiffSection> sections;
            sections.reserve(m_diffs.size());

            for (const auto& diff : m_diffs) {
                sections.push_back(convertDiff(diff));
            }

            // Store result
            {
                QMutexLocker lock(&m_impl->m_mutex);

                // Evict if at capacity
                while (static_cast<int>(m_impl->m_cache.size()) >= m_impl->m_maxSessions) {
                    m_impl->evictOneLocked();
                }

                // Remove existing entry if present
                auto existing = m_impl->m_cache.find(m_sessionId);
                if (existing != m_impl->m_cache.end()) {
                    m_impl->m_lruList.erase(existing->second.lruIt);
                    m_impl->m_cache.erase(existing);
                }

                m_impl->m_lruList.push_front(m_sessionId);
                CacheEntry entry;
                entry.sections = std::move(sections);
                entry.lruIt = m_impl->m_lruList.begin();
                m_impl->m_cache.emplace(m_sessionId, std::move(entry));
            }

            QMetaObject::invokeMethod(m_impl->m_owner, [owner = m_impl->m_owner, id = m_sessionId]() {
                emit owner->precomputationComplete(id);
            }, Qt::QueuedConnection);
        }

    private:
        Impl* m_impl;
        QString m_sessionId;
        QList<CachedDiff> m_diffs;
    };

    void evictOneLocked() {
        if (m_lruList.empty()) return;
        const QString& lruKey = m_lruList.back();
        m_cache.erase(lruKey);
        m_lruList.pop_back();
    }

    DiffPrecomputationService* m_owner;
    QMutex m_mutex;
    int m_maxSessions;

    std::map<QString, CacheEntry> m_cache;
    std::list<QString> m_lruList;  // front = most recently used
};

DiffPrecomputationService::DiffPrecomputationService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>(this))
{
}

DiffPrecomputationService::~DiffPrecomputationService() = default;

void DiffPrecomputationService::precomputeAll(const QString& sessionId, const QList<CachedDiff>& diffs) {
    m_impl->precomputeAll(sessionId, diffs);
}

std::optional<std::vector<DiffSection>> DiffPrecomputationService::getPrecomputed(const QString& sessionId) {
    return m_impl->getPrecomputed(sessionId);
}

bool DiffPrecomputationService::hasPrecomputed(const QString& sessionId) {
    return m_impl->hasPrecomputed(sessionId);
}

void DiffPrecomputationService::invalidate(const QString& sessionId) {
    m_impl->invalidate(sessionId);
}

void DiffPrecomputationService::clear() {
    m_impl->clear();
}

void DiffPrecomputationService::setCacheCapacity(int sessions) {
    m_impl->setCacheCapacity(sessions);
}

} // namespace jules
