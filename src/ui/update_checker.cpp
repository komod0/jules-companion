#include "ui/update_checker.h"

#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDir>
#include <QStandardPaths>
#include <QCryptographicHash>
#include <QProcess>
#include <QFileInfo>

namespace jules {

namespace {
const QString GITHUB_API_BASE = "https://api.github.com";
const int DEFAULT_CHECK_INTERVAL_HOURS = 24;
}

UpdateChecker::UpdateChecker(QObject* parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
    , m_currentReply(nullptr)
    , m_autoCheckTimer(new QTimer(this))
    , m_downloadFile(nullptr)
    , m_currentVersion("1.0.0")
    , m_githubOwner("google")
    , m_githubRepo("jules-companion")
    , m_checkIntervalHours(DEFAULT_CHECK_INTERVAL_HOURS)
    , m_autoCheckEnabled(true)
    , m_includePrereleases(false)
    , m_isChecking(false)
    , m_isDownloading(false)
    , m_downloadPercent(0)
{
    connect(m_autoCheckTimer, &QTimer::timeout,
            this, &UpdateChecker::onAutoCheckTimer);
}

UpdateChecker::~UpdateChecker() {
    cancelDownload();
}

void UpdateChecker::setCurrentVersion(const QString& version) {
    m_currentVersion = version;
}

void UpdateChecker::setGitHubRepo(const QString& owner, const QString& repo) {
    m_githubOwner = owner;
    m_githubRepo = repo;
}

void UpdateChecker::setCheckInterval(int hours) {
    m_checkIntervalHours = hours;
    if (m_autoCheckEnabled && m_autoCheckTimer->isActive()) {
        m_autoCheckTimer->setInterval(hours * 3600 * 1000);
    }
}

void UpdateChecker::setAutoCheck(bool enabled) {
    m_autoCheckEnabled = enabled;
    if (enabled) {
        m_autoCheckTimer->start(m_checkIntervalHours * 3600 * 1000);
    } else {
        m_autoCheckTimer->stop();
    }
}

void UpdateChecker::setIncludePrereleases(bool include) {
    m_includePrereleases = include;
}

QString UpdateChecker::currentVersion() const {
    return m_currentVersion;
}

bool UpdateChecker::isAutoCheckEnabled() const {
    return m_autoCheckEnabled;
}

int UpdateChecker::checkIntervalHours() const {
    return m_checkIntervalHours;
}

void UpdateChecker::checkForUpdates() {
    if (m_isChecking || m_isDownloading) {
        return;
    }

    m_isChecking = true;
    emit checkStarted();

    QString url = QString("%1/repos/%2/%3/releases/latest")
        .arg(GITHUB_API_BASE)
        .arg(m_githubOwner)
        .arg(m_githubRepo);

    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::UserAgentHeader, "Jules-Linux-UpdateChecker/1.0");
    request.setRawHeader("Accept", "application/vnd.github.v3+json");

    m_currentReply = m_networkManager->get(request);
    connect(m_currentReply, &QNetworkReply::finished,
            this, &UpdateChecker::onCheckReply);
}

void UpdateChecker::downloadUpdate(const UpdateInfo& info) {
    if (m_isDownloading || info.downloadUrl.isEmpty()) {
        return;
    }

    m_isDownloading = true;
    m_downloadPercent = 0;
    emit downloadStarted();

    // Prepare download path
    QString downloadPath = getDownloadPath();
    QDir().mkpath(QFileInfo(downloadPath).absolutePath());

    m_downloadFile = new QFile(downloadPath, this);
    if (!m_downloadFile->open(QIODevice::WriteOnly)) {
        m_isDownloading = false;
        emit downloadFailed(QString("Cannot create file: %1").arg(downloadPath));
        return;
    }

    QNetworkRequest request(info.downloadUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader, "Jules-Linux-UpdateChecker/1.0");

    m_currentReply = m_networkManager->get(request);
    connect(m_currentReply, &QNetworkReply::downloadProgress,
            this, &UpdateChecker::onDownloadProgress);
    connect(m_currentReply, &QNetworkReply::finished,
            this, &UpdateChecker::onDownloadFinished);
    connect(m_currentReply, &QNetworkReply::readyRead, [this]() {
        if (m_downloadFile && m_currentReply) {
            m_downloadFile->write(m_currentReply->readAll());
        }
    });
}

void UpdateChecker::cancelDownload() {
    if (m_currentReply) {
        m_currentReply->abort();
        m_currentReply->deleteLater();
        m_currentReply = nullptr;
    }

    if (m_downloadFile) {
        m_downloadFile->close();
        m_downloadFile->remove();
        delete m_downloadFile;
        m_downloadFile = nullptr;
    }

    m_isChecking = false;
    m_isDownloading = false;
    m_downloadPercent = 0;
}

bool UpdateChecker::applyUpdate() {
    if (m_downloadedPath.isEmpty() || !QFile::exists(m_downloadedPath)) {
        return false;
    }

    QString currentAppImage = getAppImagePath();
    if (currentAppImage.isEmpty()) {
        return false;
    }

    return replaceAppImage(m_downloadedPath);
}

bool UpdateChecker::isChecking() const {
    return m_isChecking;
}

bool UpdateChecker::isDownloading() const {
    return m_isDownloading;
}

int UpdateChecker::downloadProgress() const {
    return m_downloadPercent;
}

bool UpdateChecker::hasUpdate() const {
    return m_availableUpdate.has_value();
}

UpdateInfo UpdateChecker::availableUpdate() const {
    return m_availableUpdate.value_or(UpdateInfo{});
}

void UpdateChecker::onCheckReply() {
    m_isChecking = false;

    if (!m_currentReply) {
        emit checkFailed("No reply received");
        return;
    }

    if (m_currentReply->error() != QNetworkReply::NoError) {
        QString errorMsg = m_currentReply->errorString();
        m_currentReply->deleteLater();
        m_currentReply = nullptr;
        emit checkFailed(errorMsg);
        return;
    }

    QByteArray data = m_currentReply->readAll();
    m_currentReply->deleteLater();
    m_currentReply = nullptr;

    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(data, &parseError);

    if (parseError.error != QJsonParseError::NoError) {
        emit checkFailed(QString("JSON parse error: %1").arg(parseError.errorString()));
        return;
    }

    parseGitHubRelease(doc);
}

void UpdateChecker::onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal) {
    if (bytesTotal > 0) {
        m_downloadPercent = static_cast<int>((bytesReceived * 100) / bytesTotal);
        emit downloadProgress(m_downloadPercent, bytesReceived, bytesTotal);
    }
}

void UpdateChecker::onDownloadFinished() {
    m_isDownloading = false;

    if (!m_currentReply || !m_downloadFile) {
        emit downloadFailed("Download interrupted");
        return;
    }

    if (m_currentReply->error() != QNetworkReply::NoError) {
        QString errorMsg = m_currentReply->errorString();
        m_downloadFile->close();
        m_downloadFile->remove();
        delete m_downloadFile;
        m_downloadFile = nullptr;
        m_currentReply->deleteLater();
        m_currentReply = nullptr;
        emit downloadFailed(errorMsg);
        return;
    }

    // Write any remaining data
    m_downloadFile->write(m_currentReply->readAll());
    m_downloadFile->close();

    m_downloadedPath = m_downloadFile->fileName();
    
    // Make executable
    QFile::setPermissions(m_downloadedPath, 
        QFile::permissions(m_downloadedPath) | QFileDevice::ExeOwner | QFileDevice::ExeGroup);

    delete m_downloadFile;
    m_downloadFile = nullptr;
    m_currentReply->deleteLater();
    m_currentReply = nullptr;

    // Verify checksum if available
    if (m_availableUpdate.has_value() && !m_availableUpdate->checksum.isEmpty()) {
        if (!verifyChecksum(m_downloadedPath, m_availableUpdate->checksum)) {
            QFile::remove(m_downloadedPath);
            m_downloadedPath.clear();
            emit downloadFailed("Checksum verification failed");
            return;
        }
    }

    emit downloadFinished(m_downloadedPath);
}

void UpdateChecker::onAutoCheckTimer() {
    checkForUpdates();
}

void UpdateChecker::parseGitHubRelease(const QJsonDocument& doc) {
    QJsonObject release = doc.object();

    QString tagName = release["tag_name"].toString();
    bool isPrerelease = release["prerelease"].toBool();

    // Skip prereleases if not enabled
    if (isPrerelease && !m_includePrereleases) {
        emit checkFinished(false);
        return;
    }

    // Remove 'v' prefix if present
    QString version = tagName.startsWith('v') ? tagName.mid(1) : tagName;

    if (!isNewerVersion(version)) {
        m_availableUpdate.reset();
        emit checkFinished(false);
        return;
    }

    // Find Linux AppImage asset
    QJsonArray assets = release["assets"].toArray();
    QString downloadUrl;
    qint64 fileSize = 0;

    for (const QJsonValue& assetVal : assets) {
        QJsonObject asset = assetVal.toObject();
        QString name = asset["name"].toString();
        
        // Look for Linux AppImage
        if (name.contains("linux", Qt::CaseInsensitive) && 
            name.endsWith(".AppImage", Qt::CaseInsensitive)) {
            downloadUrl = asset["browser_download_url"].toString();
            fileSize = asset["size"].toVariant().toLongLong();
            break;
        }
    }

    if (downloadUrl.isEmpty()) {
        emit checkFailed("No Linux AppImage found in release");
        return;
    }

    UpdateInfo info;
    info.version = version;
    info.downloadUrl = downloadUrl;
    info.releaseNotes = release["body"].toString();
    info.fileSize = fileSize;
    info.isPrerelease = isPrerelease;

    m_availableUpdate = info;
    emit updateReady(info);
    emit checkFinished(true);
}

bool UpdateChecker::isNewerVersion(const QString& remote) const {
    QVersionNumber current = QVersionNumber::fromString(m_currentVersion);
    QVersionNumber remoteVer = QVersionNumber::fromString(remote);
    
    return remoteVer > current;
}

QString UpdateChecker::getAppImagePath() const {
    // Check APPIMAGE environment variable (set by AppImage runtime)
    QString appImage = qgetenv("APPIMAGE");
    if (!appImage.isEmpty() && QFile::exists(appImage)) {
        return appImage;
    }

    // Fallback to application file path
    return QCoreApplication::applicationFilePath();
}

QString UpdateChecker::getDownloadPath() const {
    QString cacheDir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    return QString("%1/updates/Jules-new.AppImage").arg(cacheDir);
}

bool UpdateChecker::verifyChecksum(const QString& filePath, const QString& expectedHash) {
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        return false;
    }

    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(&file);
    file.close();

    QString computed = hash.result().toHex();
    return computed.compare(expectedHash, Qt::CaseInsensitive) == 0;
}

bool UpdateChecker::replaceAppImage(const QString& newPath) {
    QString currentPath = getAppImagePath();
    
    if (currentPath.isEmpty()) {
        return false;
    }

    // Create backup
    QString backupPath = currentPath + ".backup";
    QFile::remove(backupPath);
    
    if (!QFile::rename(currentPath, backupPath)) {
        return false;
    }

    // Move new version into place
    if (!QFile::rename(newPath, currentPath)) {
        // Restore backup on failure
        QFile::rename(backupPath, currentPath);
        return false;
    }

    // Clean up backup
    QFile::remove(backupPath);

    // Make executable
    QFile::setPermissions(currentPath,
        QFile::permissions(currentPath) | QFileDevice::ExeOwner | QFileDevice::ExeGroup);

    // Restart application
    QProcess::startDetached(currentPath, QCoreApplication::arguments());
    QCoreApplication::quit();

    return true;
}

} // namespace jules
