#pragma once

#include "rendering/diff_renderer.h"

#include <cstddef>
#include <functional>
#include <list>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace jules {

class SharedSyntaxCache {
public:
    struct CacheKey {
        std::size_t contentHash = 0;
        std::string language;
        bool isDarkMode = true;

        bool operator==(const CacheKey& other) const {
            return contentHash == other.contentHash &&
                   language == other.language &&
                   isDarkMode == other.isDarkMode;
        }
    };

    struct CacheKeyHash {
        std::size_t operator()(const CacheKey& key) const {
            std::size_t h = key.contentHash;
            h ^= std::hash<std::string>{}(key.language) + 0x9e3779b9 + (h << 6) + (h >> 2);
            h ^= std::hash<bool>{}(key.isDarkMode) + 0x9e3779b9 + (h << 6) + (h >> 2);
            return h;
        }
    };

    explicit SharedSyntaxCache(std::size_t capacity = 5000);
    ~SharedSyntaxCache();

    SharedSyntaxCache(const SharedSyntaxCache&) = delete;
    SharedSyntaxCache& operator=(const SharedSyntaxCache&) = delete;

    std::optional<std::vector<SyntaxColorToken>> get(const CacheKey& key);
    void put(const CacheKey& key, std::vector<SyntaxColorToken> tokens);
    void clear();
    std::size_t size() const;
    std::size_t capacity() const;
    void setCapacity(std::size_t cap);
    float hitRate() const;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace jules
