#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QString>
#include <QVersionNumber>
#include <QTimer>
#include <QFile>

namespace jules {

/**
 * Information about an available update
 */
struct UpdateInfo {
    QString version;
    QString downloadUrl;
    QString releaseNotes;
    qint64 fileSize = 0;
    QString checksum;  // SHA256
    bool isPrerelease = false;
};

/**
 * Auto-update checker for AppImage distributions.
 * 
 * Features:
 * - Checks GitHub releases for newer versions
 * - Downloads new AppImage in background
 * - Supports self-replacement and restart
 * - Configurable check interval
 */
class UpdateChecker : public QObject {
    Q_OBJECT

public:
    explicit UpdateChecker(QObject* parent = nullptr);
    ~UpdateChecker() override;

    // Configuration
    void setCurrentVersion(const QString& version);
    void setGitHubRepo(const QString& owner, const QString& repo);
    void setCheckInterval(int hours);
    void setAutoCheck(bool enabled);
    void setIncludePrereleases(bool include);

    QString currentVersion() const;
    bool isAutoCheckEnabled() const;
    int checkIntervalHours() const;

    // Update operations
    void checkForUpdates();
    void downloadUpdate(const UpdateInfo& info);
    void cancelDownload();
    bool applyUpdate();

    // State
    bool isChecking() const;
    bool isDownloading() const;
    int downloadProgress() const;
    bool hasUpdate() const;
    UpdateInfo availableUpdate() const;

signals:
    void checkStarted();
    void checkFinished(bool updateAvailable);
    void checkFailed(const QString& error);
    
    void downloadStarted();
    void downloadProgress(int percent, qint64 bytesReceived, qint64 bytesTotal);
    void downloadFinished(const QString& filePath);
    void downloadFailed(const QString& error);
    
    void updateReady(const UpdateInfo& info);

private slots:
    void onCheckReply();
    void onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal);
    void onDownloadFinished();
    void onAutoCheckTimer();

private:
    void parseGitHubRelease(const QJsonDocument& doc);
    bool isNewerVersion(const QString& remote) const;
    QString getAppImagePath() const;
    QString getDownloadPath() const;
    bool verifyChecksum(const QString& filePath, const QString& expectedHash);
    bool replaceAppImage(const QString& newPath);

    QNetworkAccessManager* m_networkManager;
    QNetworkReply* m_currentReply;
    QTimer* m_autoCheckTimer;
    QFile* m_downloadFile;

    QString m_currentVersion;
    QString m_githubOwner;
    QString m_githubRepo;
    int m_checkIntervalHours;
    bool m_autoCheckEnabled;
    bool m_includePrereleases;

    bool m_isChecking;
    bool m_isDownloading;
    int m_downloadPercent;
    
    std::optional<UpdateInfo> m_availableUpdate;
    QString m_downloadedPath;
};

} // namespace jules
