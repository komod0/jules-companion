#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QTimer>
#include <QEventLoop>
#include <QMetaMethod>
#include <memory>
#include <type_traits>

#include "data/network_monitor.h"

namespace jules {
namespace test {

class NetworkMonitorTest : public ::testing::Test {
protected:
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }
};

TEST_F(NetworkMonitorTest, DefaultStateIsOnline) {
    NetworkMonitor monitor;
    EXPECT_TRUE(monitor.isOnline());
}

TEST_F(NetworkMonitorTest, StartMonitoringDoesNotCrash) {
    NetworkMonitor monitor;
    EXPECT_NO_THROW({
        monitor.startMonitoring();
    });
    monitor.stopMonitoring();
}

TEST_F(NetworkMonitorTest, StopWithoutStartDoesNotCrash) {
    NetworkMonitor monitor;
    EXPECT_NO_THROW({
        monitor.stopMonitoring();
    });
}

TEST_F(NetworkMonitorTest, DoubleStartDoesNotCrash) {
    NetworkMonitor monitor;
    monitor.startMonitoring();
    EXPECT_NO_THROW({
        monitor.startMonitoring();
    });
    monitor.stopMonitoring();
}

TEST_F(NetworkMonitorTest, DoubleStopDoesNotCrash) {
    NetworkMonitor monitor;
    monitor.startMonitoring();
    monitor.stopMonitoring();
    EXPECT_NO_THROW({
        monitor.stopMonitoring();
    });
}

TEST_F(NetworkMonitorTest, ConnectivityChangedSignalIsValid) {
    NetworkMonitor monitor;
    QSignalSpy spy(&monitor, &NetworkMonitor::connectivityChanged);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(NetworkMonitorTest, ConnectivityRestoredSignalIsValid) {
    NetworkMonitor monitor;
    QSignalSpy spy(&monitor, &NetworkMonitor::connectivityRestored);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(NetworkMonitorTest, DestructorStopsMonitoring) {
    // Verify no crash when destroying an active monitor
    EXPECT_NO_THROW({
        NetworkMonitor monitor;
        monitor.startMonitoring();
        // destructor should call stopMonitoring
    });
}

TEST_F(NetworkMonitorTest, ConnectivityChangedSignalCarriesBool) {
    NetworkMonitor monitor;
    QSignalSpy spy(&monitor, &NetworkMonitor::connectivityChanged);
    ASSERT_TRUE(spy.isValid());
    // Verify the signal signature accepts bool by checking the spy parameterTypes
    QList<int> paramTypes = spy.at(0).isEmpty() ? QList<int>{} : QList<int>{};
    // The signal is connectivityChanged(bool), so if it ever fires, first arg is bool.
    // We validate the spy is properly connected (isValid) and that the signal signature
    // is correct by checking the signal's parameter count.
    EXPECT_EQ(QMetaMethod::fromSignal(&NetworkMonitor::connectivityChanged).parameterCount(), 1);
    EXPECT_EQ(QMetaMethod::fromSignal(&NetworkMonitor::connectivityChanged).parameterType(0),
              QMetaType::Bool);
}

TEST_F(NetworkMonitorTest, IsOnlineReturnsDefault) {
    NetworkMonitor monitor;
    // Without any connectivity events, default should be true
    EXPECT_TRUE(monitor.isOnline());
}

TEST_F(NetworkMonitorTest, StartMonitoringPreservesOnlineState) {
    NetworkMonitor monitor;
    EXPECT_TRUE(monitor.isOnline());
    monitor.startMonitoring();
    EXPECT_TRUE(monitor.isOnline());
    monitor.stopMonitoring();
}

TEST_F(NetworkMonitorTest, StopAndRestartDoesNotCrash) {
    NetworkMonitor monitor;
    monitor.startMonitoring();
    monitor.stopMonitoring();
    EXPECT_NO_THROW({
        monitor.startMonitoring();
    });
    monitor.stopMonitoring();
}

TEST_F(NetworkMonitorTest, DestroyDuringActiveMonitoring) {
    EXPECT_NO_THROW({
        auto monitor = std::make_unique<NetworkMonitor>();
        monitor->startMonitoring();
        // Destroy immediately while monitoring is active
        monitor.reset();
    });
}

TEST_F(NetworkMonitorTest, MultipleStartStopCycles) {
    NetworkMonitor monitor;
    EXPECT_NO_THROW({
        for (int i = 0; i < 5; ++i) {
            monitor.startMonitoring();
            monitor.stopMonitoring();
        }
    });
}

TEST_F(NetworkMonitorTest, ProcessEventsAfterStart) {
    NetworkMonitor monitor;
    monitor.startMonitoring();
    EXPECT_NO_THROW({
        processEvents(100);
    });
    monitor.stopMonitoring();
}

TEST_F(NetworkMonitorTest, WaitForEventsAfterStop) {
    NetworkMonitor monitor;
    monitor.startMonitoring();
    monitor.stopMonitoring();
    EXPECT_NO_THROW({
        processEvents(100);
    });
}

TEST_F(NetworkMonitorTest, MonitorIsNonCopyable) {
    // NetworkMonitor inherits from QObject, which is non-copyable.
    // Verify this at compile time via type traits.
    EXPECT_FALSE(std::is_copy_constructible<NetworkMonitor>::value);
    EXPECT_FALSE(std::is_copy_assignable<NetworkMonitor>::value);
}

TEST_F(NetworkMonitorTest, StartEmitsNoImmediateSignal) {
    NetworkMonitor monitor;
    QSignalSpy spy(&monitor, &NetworkMonitor::connectivityChanged);
    ASSERT_TRUE(spy.isValid());

    monitor.startMonitoring();
    // No immediate signal should be emitted on start
    EXPECT_EQ(spy.count(), 0);
    monitor.stopMonitoring();
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
