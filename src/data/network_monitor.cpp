#include "data/network_monitor.h"

#include <QNetworkInformation>
#include <QNetworkRequest>
#include <QDebug>

namespace jules {

NetworkMonitor::NetworkMonitor(QObject* parent)
    : QObject(parent)
{
    m_probeTimer.setInterval(PROBE_INTERVAL_MS);
    connect(&m_probeTimer, &QTimer::timeout, this, &NetworkMonitor::sendProbe);
}

NetworkMonitor::~NetworkMonitor()
{
    stopMonitoring();
}

bool NetworkMonitor::isOnline() const
{
    return m_online;
}

void NetworkMonitor::startMonitoring()
{
    if (m_monitoring) {
        return;
    }
    m_monitoring = true;
    qDebug() << "[NetworkMonitor] Starting connectivity monitoring";

    // Try QNetworkInformation native backend first (Qt 6.4+)
#if QT_VERSION >= QT_VERSION_CHECK(6, 4, 0)
    if (QNetworkInformation::loadDefaultBackend() || QNetworkInformation::loadBackendByFeatures(
            QNetworkInformation::Feature::Reachability)) {
        auto* netInfo = QNetworkInformation::instance();
        if (netInfo) {
            m_usingNativeBackend = true;
            qDebug() << "[NetworkMonitor] Using native backend:" << netInfo->backendName();

            connect(netInfo, &QNetworkInformation::reachabilityChanged, this,
                [this](QNetworkInformation::Reachability reachability) {
                    bool online = (reachability == QNetworkInformation::Reachability::Online);
                    qDebug() << "[NetworkMonitor] Reachability changed:" << static_cast<int>(reachability)
                             << "online=" << online;
                    setOnline(online);
                });

            bool initialOnline = (netInfo->reachability() == QNetworkInformation::Reachability::Online);
            m_online = initialOnline;
            qDebug() << "[NetworkMonitor] Initial state: online=" << initialOnline;
            return;
        }
    }
#endif

    // Fallback: periodic HTTP probe
    qDebug() << "[NetworkMonitor] No native backend available, using fallback probe";
    m_usingNativeBackend = false;
    startFallbackProbe();
}

void NetworkMonitor::stopMonitoring()
{
    if (!m_monitoring) {
        return;
    }
    m_monitoring = false;
    qDebug() << "[NetworkMonitor] Stopping connectivity monitoring";

    if (m_usingNativeBackend) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 4, 0)
        auto* netInfo = QNetworkInformation::instance();
        if (netInfo) {
            disconnect(netInfo, nullptr, this, nullptr);
        }
#endif
    } else {
        stopFallbackProbe();
    }
}

void NetworkMonitor::setOnline(bool online)
{
    if (m_online == online) {
        return;
    }

    bool wasOffline = !m_online;
    m_online = online;

    qDebug() << "[NetworkMonitor] Connectivity changed: online=" << online;
    emit connectivityChanged(online);

    if (wasOffline && online) {
        qDebug() << "[NetworkMonitor] Connectivity restored (was offline)";
        emit connectivityRestored();
    }
}

void NetworkMonitor::startFallbackProbe()
{
    if (!m_nam) {
        m_nam = new QNetworkAccessManager(this);
    }
    sendProbe();
    m_probeTimer.start();
}

void NetworkMonitor::stopFallbackProbe()
{
    m_probeTimer.stop();
    if (m_pendingProbe) {
        m_pendingProbe->abort();
        m_pendingProbe->deleteLater();
        m_pendingProbe = nullptr;
    }
}

void NetworkMonitor::sendProbe()
{
    if (m_pendingProbe) {
        return;
    }

    QNetworkRequest request(QUrl("https://www.google.com"));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(PROBE_TIMEOUT_MS);

    m_pendingProbe = m_nam->head(request);
    connect(m_pendingProbe, &QNetworkReply::finished,
            this, &NetworkMonitor::onProbeFinished);
}

void NetworkMonitor::onProbeFinished()
{
    if (!m_pendingProbe) {
        return;
    }

    auto* reply = m_pendingProbe;
    m_pendingProbe = nullptr;

    bool success = (reply->error() == QNetworkReply::NoError);
    reply->deleteLater();

    setOnline(success);
}

void NetworkMonitor::onProbeTimeout()
{
    if (m_pendingProbe) {
        m_pendingProbe->abort();
    }
}

} // namespace jules
