#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QTimer>
#include <QEventLoop>

#include <thread>
#include <vector>

#include "rendering/diff_precomputation_service.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

class DiffPrecomputationTest : public ::testing::Test {
protected:
    void processEvents(int timeoutMs = 200) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    QList<CachedDiff> makeDiffs(int count) {
        QList<CachedDiff> diffs;
        for (int i = 0; i < count; ++i) {
            CachedDiff d;
            d.patch = QString("--- a/file%1.cpp\n+++ b/file%1.cpp\n@@ -1,3 +1,3 @@\n context\n-old line\n+new line\n context").arg(i);
            d.language = "cpp";
            d.filename = QString("file%1.cpp").arg(i);
            diffs.append(d);
        }
        return diffs;
    }
};

TEST_F(DiffPrecomputationTest, InitialStateHasNoPrecomputed) {
    DiffPrecomputationService service;
    EXPECT_FALSE(service.hasPrecomputed("session-1"));
}

TEST_F(DiffPrecomputationTest, GetPrecomputedReturnsNulloptForUnknown) {
    DiffPrecomputationService service;
    auto result = service.getPrecomputed("session-1");
    EXPECT_FALSE(result.has_value());
}

TEST_F(DiffPrecomputationTest, PrecomputeAllStoresResults) {
    DiffPrecomputationService service;

    QSignalSpy spy(&service, &DiffPrecomputationService::precomputationComplete);
    ASSERT_TRUE(spy.isValid());

    service.precomputeAll("session-1", makeDiffs(2));

    // Wait for background thread to complete
    processEvents(500);

    EXPECT_TRUE(service.hasPrecomputed("session-1"));

    auto result = service.getPrecomputed("session-1");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 2u);
}

TEST_F(DiffPrecomputationTest, InvalidateRemoves) {
    DiffPrecomputationService service;

    service.precomputeAll("session-1", makeDiffs(1));
    processEvents(500);

    EXPECT_TRUE(service.hasPrecomputed("session-1"));

    service.invalidate("session-1");
    EXPECT_FALSE(service.hasPrecomputed("session-1"));
}

TEST_F(DiffPrecomputationTest, ClearRemovesAll) {
    DiffPrecomputationService service;

    service.precomputeAll("session-1", makeDiffs(1));
    service.precomputeAll("session-2", makeDiffs(1));
    processEvents(500);

    service.clear();
    EXPECT_FALSE(service.hasPrecomputed("session-1"));
    EXPECT_FALSE(service.hasPrecomputed("session-2"));
}

TEST_F(DiffPrecomputationTest, InvalidateNonExistentDoesNotCrash) {
    DiffPrecomputationService service;
    EXPECT_NO_THROW({
        service.invalidate("nonexistent");
    });
}

TEST_F(DiffPrecomputationTest, PrecomputationCompleteSignalEmitted) {
    DiffPrecomputationService service;

    QSignalSpy spy(&service, &DiffPrecomputationService::precomputationComplete);
    ASSERT_TRUE(spy.isValid());

    service.precomputeAll("session-1", makeDiffs(1));
    processEvents(500);

    EXPECT_GE(spy.count(), 1);
    EXPECT_EQ(spy.at(0).at(0).toString(), "session-1");
}

TEST_F(DiffPrecomputationTest, CacheCapacityEviction) {
    DiffPrecomputationService service;
    service.setCacheCapacity(2);

    service.precomputeAll("s1", makeDiffs(1));
    processEvents(300);
    service.precomputeAll("s2", makeDiffs(1));
    processEvents(300);
    service.precomputeAll("s3", makeDiffs(1));
    processEvents(300);

    // s1 should have been evicted (capacity is 2)
    EXPECT_FALSE(service.hasPrecomputed("s1"));
    EXPECT_TRUE(service.hasPrecomputed("s2"));
    EXPECT_TRUE(service.hasPrecomputed("s3"));
}

TEST_F(DiffPrecomputationTest, ConcurrentPrecomputeDoesNotCrash) {
    DiffPrecomputationService service;

    // Launch 3 precomputeAll calls for different sessions without waiting
    service.precomputeAll("concurrent-1", makeDiffs(3));
    service.precomputeAll("concurrent-2", makeDiffs(3));
    service.precomputeAll("concurrent-3", makeDiffs(3));

    processEvents(1000);

    // At least some should have completed
    int completed = 0;
    if (service.hasPrecomputed("concurrent-1")) ++completed;
    if (service.hasPrecomputed("concurrent-2")) ++completed;
    if (service.hasPrecomputed("concurrent-3")) ++completed;
    EXPECT_GE(completed, 1);
}

TEST_F(DiffPrecomputationTest, PrecomputeWhilePreviousRunning) {
    DiffPrecomputationService service;

    QSignalSpy spy(&service, &DiffPrecomputationService::precomputationComplete);
    ASSERT_TRUE(spy.isValid());

    // Start one, immediately start another for a different session
    service.precomputeAll("running-1", makeDiffs(2));
    service.precomputeAll("running-2", makeDiffs(2));

    processEvents(500);

    EXPECT_TRUE(service.hasPrecomputed("running-1"));
    EXPECT_TRUE(service.hasPrecomputed("running-2"));
}

TEST_F(DiffPrecomputationTest, GetPrecomputedDuringPrecomputation) {
    DiffPrecomputationService service;

    service.precomputeAll("in-flight", makeDiffs(3));

    // Immediately call getPrecomputed - may return nullopt or a result, must not crash
    EXPECT_NO_THROW({
        auto result = service.getPrecomputed("in-flight");
        (void)result;
    });

    processEvents(500);
}

TEST_F(DiffPrecomputationTest, HasPrecomputedFromMultipleThreads) {
    DiffPrecomputationService service;

    service.precomputeAll("threaded", makeDiffs(2));
    processEvents(500);

    ASSERT_TRUE(service.hasPrecomputed("threaded"));

    // Check hasPrecomputed from 3 std::threads simultaneously
    std::vector<bool> results(3, false);
    std::vector<std::thread> threads;
    for (int i = 0; i < 3; ++i) {
        threads.emplace_back([&service, &results, i]() {
            results[i] = service.hasPrecomputed("threaded");
        });
    }
    for (auto& t : threads) {
        t.join();
    }

    for (int i = 0; i < 3; ++i) {
        EXPECT_TRUE(results[i]) << "Thread " << i << " got false";
    }
}

TEST_F(DiffPrecomputationTest, ClearDuringPrecomputation) {
    DiffPrecomputationService service;

    service.precomputeAll("clear-target", makeDiffs(5));

    // Immediately clear while precomputation may still be running
    EXPECT_NO_THROW({
        service.clear();
    });

    processEvents(500);

    // After clear and processing, the session should not be cached
    // (or if re-added by late completion, that is also acceptable - no crash is the goal)
}

TEST_F(DiffPrecomputationTest, PrecomputeLargeDiffSet) {
    DiffPrecomputationService service;

    QSignalSpy spy(&service, &DiffPrecomputationService::precomputationComplete);
    ASSERT_TRUE(spy.isValid());

    service.precomputeAll("large-set", makeDiffs(50));
    processEvents(2000);

    ASSERT_TRUE(service.hasPrecomputed("large-set"));

    auto result = service.getPrecomputed("large-set");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 50u);
}

TEST_F(DiffPrecomputationTest, PrecomputeEmptyDiffList) {
    DiffPrecomputationService service;

    // Precompute with 0 diffs - should not crash
    EXPECT_NO_THROW({
        service.precomputeAll("empty", makeDiffs(0));
    });

    processEvents(300);

    // The service may or may not cache an empty result - either way, no crash
    auto result = service.getPrecomputed("empty");
    if (result.has_value()) {
        EXPECT_EQ(result->size(), 0u);
    }
}

TEST_F(DiffPrecomputationTest, CacheCapacityOneEvictsImmediately) {
    DiffPrecomputationService service;
    service.setCacheCapacity(1);

    service.precomputeAll("s1", makeDiffs(1));
    processEvents(500);
    ASSERT_TRUE(service.hasPrecomputed("s1"));

    service.precomputeAll("s2", makeDiffs(1));
    processEvents(500);

    // s1 should have been evicted since capacity is 1
    EXPECT_FALSE(service.hasPrecomputed("s1"));
    EXPECT_TRUE(service.hasPrecomputed("s2"));
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
