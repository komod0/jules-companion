#include <gtest/gtest.h>

#include "rendering/shared_syntax_cache.h"

#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace jules {
namespace test {

class SharedSyntaxCacheTest : public ::testing::Test {
protected:
    SharedSyntaxCache::CacheKey makeKey(const std::string& content,
                                         const std::string& lang = "cpp",
                                         bool dark = true) {
        SharedSyntaxCache::CacheKey key;
        key.contentHash = std::hash<std::string>{}(content);
        key.language = lang;
        key.isDarkMode = dark;
        return key;
    }

    std::vector<SyntaxColorToken> makeTokens(int count) {
        std::vector<SyntaxColorToken> tokens;
        for (int i = 0; i < count; ++i) {
            SyntaxColorToken t;
            t.start = static_cast<std::size_t>(i * 10);
            t.end = static_cast<std::size_t>(i * 10 + 5);
            t.color = {0.5f, 0.5f, 0.5f, 1.0f};
            tokens.push_back(t);
        }
        return tokens;
    }
};

TEST_F(SharedSyntaxCacheTest, DefaultCapacity) {
    SharedSyntaxCache cache;
    EXPECT_EQ(cache.capacity(), 5000u);
    EXPECT_EQ(cache.size(), 0u);
}

TEST_F(SharedSyntaxCacheTest, CustomCapacity) {
    SharedSyntaxCache cache(100);
    EXPECT_EQ(cache.capacity(), 100u);
}

TEST_F(SharedSyntaxCacheTest, PutAndGet) {
    SharedSyntaxCache cache(10);
    auto key = makeKey("hello");
    auto tokens = makeTokens(3);

    cache.put(key, tokens);
    EXPECT_EQ(cache.size(), 1u);

    auto result = cache.get(key);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 3u);
}

TEST_F(SharedSyntaxCacheTest, CacheMissReturnsNullopt) {
    SharedSyntaxCache cache(10);
    auto key = makeKey("nonexistent");

    auto result = cache.get(key);
    EXPECT_FALSE(result.has_value());
}

TEST_F(SharedSyntaxCacheTest, LruEviction) {
    SharedSyntaxCache cache(3);

    cache.put(makeKey("a"), makeTokens(1));
    cache.put(makeKey("b"), makeTokens(1));
    cache.put(makeKey("c"), makeTokens(1));
    EXPECT_EQ(cache.size(), 3u);

    // Adding a 4th entry should evict the oldest ("a")
    cache.put(makeKey("d"), makeTokens(1));
    EXPECT_EQ(cache.size(), 3u);

    // "a" should be evicted
    EXPECT_FALSE(cache.get(makeKey("a")).has_value());
    // "b", "c", "d" should be present
    EXPECT_TRUE(cache.get(makeKey("b")).has_value());
    EXPECT_TRUE(cache.get(makeKey("c")).has_value());
    EXPECT_TRUE(cache.get(makeKey("d")).has_value());
}

TEST_F(SharedSyntaxCacheTest, LruAccessPromotes) {
    SharedSyntaxCache cache(3);

    cache.put(makeKey("a"), makeTokens(1));
    cache.put(makeKey("b"), makeTokens(1));
    cache.put(makeKey("c"), makeTokens(1));

    // Access "a" to promote it
    cache.get(makeKey("a"));

    // Add "d" -> should evict "b" (now the oldest)
    cache.put(makeKey("d"), makeTokens(1));

    EXPECT_TRUE(cache.get(makeKey("a")).has_value());
    EXPECT_FALSE(cache.get(makeKey("b")).has_value());
    EXPECT_TRUE(cache.get(makeKey("c")).has_value());
    EXPECT_TRUE(cache.get(makeKey("d")).has_value());
}

TEST_F(SharedSyntaxCacheTest, ClearRemovesAllEntries) {
    SharedSyntaxCache cache(10);
    cache.put(makeKey("a"), makeTokens(1));
    cache.put(makeKey("b"), makeTokens(1));
    EXPECT_EQ(cache.size(), 2u);

    cache.clear();
    EXPECT_EQ(cache.size(), 0u);
    EXPECT_FALSE(cache.get(makeKey("a")).has_value());
}

TEST_F(SharedSyntaxCacheTest, HitRateAccuracy) {
    SharedSyntaxCache cache(10);
    auto key = makeKey("test");
    cache.put(key, makeTokens(1));

    // 2 hits
    cache.get(key);
    cache.get(key);
    // 1 miss
    cache.get(makeKey("missing"));

    // 2 hits / 3 total = 0.666...
    float rate = cache.hitRate();
    EXPECT_GT(rate, 0.6f);
    EXPECT_LT(rate, 0.7f);
}

TEST_F(SharedSyntaxCacheTest, SetCapacity) {
    SharedSyntaxCache cache(10);
    cache.put(makeKey("a"), makeTokens(1));
    cache.put(makeKey("b"), makeTokens(1));
    cache.put(makeKey("c"), makeTokens(1));
    EXPECT_EQ(cache.size(), 3u);

    cache.setCapacity(2);
    EXPECT_EQ(cache.capacity(), 2u);
    EXPECT_LE(cache.size(), 2u);
}

TEST_F(SharedSyntaxCacheTest, DifferentDarkModeKeysAreDistinct) {
    SharedSyntaxCache cache(10);
    auto lightKey = makeKey("code", "cpp", false);
    auto darkKey = makeKey("code", "cpp", true);

    cache.put(lightKey, makeTokens(2));
    cache.put(darkKey, makeTokens(5));

    auto lightResult = cache.get(lightKey);
    auto darkResult = cache.get(darkKey);

    ASSERT_TRUE(lightResult.has_value());
    ASSERT_TRUE(darkResult.has_value());
    EXPECT_EQ(lightResult->size(), 2u);
    EXPECT_EQ(darkResult->size(), 5u);
}

TEST_F(SharedSyntaxCacheTest, BasicConcurrentAccess) {
    SharedSyntaxCache cache(1000);

    // Pre-populate some entries
    for (int i = 0; i < 100; ++i) {
        cache.put(makeKey("entry_" + std::to_string(i)), makeTokens(2));
    }

    // Launch multiple threads reading and writing concurrently
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; ++t) {
        threads.emplace_back([&cache, t, this]() {
            for (int i = 0; i < 50; ++i) {
                std::string id = std::to_string(t) + "_" + std::to_string(i);
                cache.put(makeKey(id), makeTokens(1));
                cache.get(makeKey("entry_" + std::to_string(i % 100)));
            }
        });
    }

    for (auto& th : threads) {
        th.join();
    }

    // Just verify no crash and cache is in a valid state
    EXPECT_GT(cache.size(), 0u);
}

} // namespace test
} // namespace jules
