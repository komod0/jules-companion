#pragma once

#include <QObject>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QNetworkReply>

namespace jules {

class NetworkMonitor : public QObject {
    Q_OBJECT

public:
    explicit NetworkMonitor(QObject* parent = nullptr);
    ~NetworkMonitor() override;

    bool isOnline() const;

    void startMonitoring();
    void stopMonitoring();

signals:
    void connectivityChanged(bool isOnline);
    void connectivityRestored();

private slots:
    void onProbeFinished();
    void onProbeTimeout();

private:
    void setOnline(bool online);
    void startFallbackProbe();
    void stopFallbackProbe();
    void sendProbe();

    bool m_online = true;
    bool m_monitoring = false;
    bool m_usingNativeBackend = false;

    QTimer m_probeTimer;
    QNetworkAccessManager* m_nam = nullptr;
    QNetworkReply* m_pendingProbe = nullptr;

    static constexpr int PROBE_INTERVAL_MS = 15000;
    static constexpr int PROBE_TIMEOUT_MS = 10000;
};

} // namespace jules
