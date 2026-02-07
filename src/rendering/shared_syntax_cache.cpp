#include "rendering/shared_syntax_cache.h"

#include <QDebug>

#include <algorithm>
#include <atomic>
#include <list>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>

namespace jules {

class SharedSyntaxCache::Impl {
public:
    using CacheKey = SharedSyntaxCache::CacheKey;
    using CacheKeyHash = SharedSyntaxCache::CacheKeyHash;
    using Value = std::vector<SyntaxColorToken>;
    using ListIterator = std::list<CacheKey>::iterator;

    explicit Impl(std::size_t capacity)
        : m_capacity(capacity)
    {
    }

    std::optional<Value> get(const CacheKey& key) {
        std::shared_lock lock(m_mutex);
        auto it = m_map.find(key);
        if (it == m_map.end()) {
            m_misses.fetch_add(1, std::memory_order_relaxed);
            return std::nullopt;
        }

        m_hits.fetch_add(1, std::memory_order_relaxed);

        // Move to front of LRU list (requires exclusive lock)
        lock.unlock();
        {
            std::unique_lock writeLock(m_mutex);
            auto mapIt = m_map.find(key);
            if (mapIt != m_map.end()) {
                m_lruList.splice(m_lruList.begin(), m_lruList, mapIt->second.lruIt);
                return mapIt->second.tokens;
            }
        }
        return std::nullopt;
    }

    void put(const CacheKey& key, Value tokens) {
        std::unique_lock lock(m_mutex);

        auto it = m_map.find(key);
        if (it != m_map.end()) {
            // Update existing entry
            it->second.tokens = std::move(tokens);
            m_lruList.splice(m_lruList.begin(), m_lruList, it->second.lruIt);
            return;
        }

        // Evict if at capacity
        if (m_map.size() >= m_capacity) {
            evictLocked();
        }

        // Insert new entry
        m_lruList.push_front(key);
        CacheEntry entry;
        entry.tokens = std::move(tokens);
        entry.lruIt = m_lruList.begin();
        m_map.emplace(key, std::move(entry));
    }

    void clear() {
        std::unique_lock lock(m_mutex);
        m_map.clear();
        m_lruList.clear();
        m_hits.store(0, std::memory_order_relaxed);
        m_misses.store(0, std::memory_order_relaxed);
    }

    std::size_t size() const {
        std::shared_lock lock(m_mutex);
        return m_map.size();
    }

    std::size_t capacity() const {
        std::shared_lock lock(m_mutex);
        return m_capacity;
    }

    void setCapacity(std::size_t cap) {
        std::unique_lock lock(m_mutex);
        m_capacity = std::max(cap, std::size_t{1});
        while (m_map.size() > m_capacity) {
            evictOneLocked();
        }
    }

    float hitRate() const {
        uint64_t hits = m_hits.load(std::memory_order_relaxed);
        uint64_t misses = m_misses.load(std::memory_order_relaxed);
        uint64_t total = hits + misses;
        if (total == 0) return 0.0f;
        return static_cast<float>(hits) / static_cast<float>(total);
    }

private:
    struct CacheEntry {
        Value tokens;
        ListIterator lruIt;
    };

    // Evict 10% of entries. Caller must hold exclusive lock.
    void evictLocked() {
        std::size_t evictCount = std::max(m_capacity / 10, std::size_t{1});
        for (std::size_t i = 0; i < evictCount && !m_lruList.empty(); ++i) {
            evictOneLocked();
        }
    }

    void evictOneLocked() {
        if (m_lruList.empty()) return;
        const auto& lruKey = m_lruList.back();
        m_map.erase(lruKey);
        m_lruList.pop_back();
    }

    mutable std::shared_mutex m_mutex;
    std::size_t m_capacity;

    std::unordered_map<CacheKey, CacheEntry, CacheKeyHash> m_map;
    std::list<CacheKey> m_lruList;  // front = most recently used

    std::atomic<uint64_t> m_hits{0};
    std::atomic<uint64_t> m_misses{0};
};

SharedSyntaxCache::SharedSyntaxCache(std::size_t capacity)
    : m_impl(std::make_unique<Impl>(capacity))
{
}

SharedSyntaxCache::~SharedSyntaxCache() = default;

std::optional<std::vector<SyntaxColorToken>> SharedSyntaxCache::get(const CacheKey& key) {
    return m_impl->get(key);
}

void SharedSyntaxCache::put(const CacheKey& key, std::vector<SyntaxColorToken> tokens) {
    m_impl->put(key, std::move(tokens));
}

void SharedSyntaxCache::clear() {
    m_impl->clear();
}

std::size_t SharedSyntaxCache::size() const {
    return m_impl->size();
}

std::size_t SharedSyntaxCache::capacity() const {
    return m_impl->capacity();
}

void SharedSyntaxCache::setCapacity(std::size_t cap) {
    m_impl->setCapacity(cap);
}

float SharedSyntaxCache::hitRate() const {
    return m_impl->hitRate();
}

} // namespace jules
