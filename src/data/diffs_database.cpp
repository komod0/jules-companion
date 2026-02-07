#include "data/diffs_database.h"

#include <QDir>
#include <QFileInfo>
#include <QSqlQuery>
#include <QSqlError>
#include <QDebug>

namespace jules {

int DiffsDatabase::s_connectionCounter = 0;

DiffsDatabase::DiffsDatabase(const QString& dataPath, QObject* parent)
    : QObject(parent)
    , m_dataPath(dataPath)
    , m_connectionName(QString("jules_diffs_db_%1").arg(++s_connectionCounter))
{
    m_dbPath = QDir(m_dataPath).filePath("diffs.db");
}

DiffsDatabase::~DiffsDatabase()
{
    if (m_db.isOpen()) {
        m_db.close();
    }
    QSqlDatabase::removeDatabase(m_connectionName);
}

bool DiffsDatabase::initialize()
{
    QDir dir(m_dataPath);
    if (!dir.exists()) {
        if (!dir.mkpath(".")) {
            qWarning() << "[DiffsDatabase] Failed to create data directory:" << m_dataPath;
            return false;
        }
    }

    m_db = QSqlDatabase::addDatabase("QSQLITE", m_connectionName);
    m_db.setDatabaseName(m_dbPath);

    if (!m_db.open()) {
        qWarning() << "[DiffsDatabase] Failed to open database:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    query.exec("PRAGMA journal_mode=WAL");
    query.exec("PRAGMA foreign_keys=ON");
    query.exec("PRAGMA synchronous=NORMAL");

    return runMigrations();
}

bool DiffsDatabase::saveDiffs(const QString& sessionId, const QList<CachedDiff>& diffs)
{
    deleteDiffs(sessionId);

    QSqlDatabase sqlDb = m_db;
    sqlDb.transaction();

    QSqlQuery query(sqlDb);
    query.prepare(R"(
        INSERT INTO cached_diffs (session_id, patch, language, filename, order_index)
        VALUES (?, ?, ?, ?, ?)
    )");

    int orderIndex = 0;
    for (const auto& diff : diffs) {
        query.addBindValue(sessionId);
        query.addBindValue(diff.patch);
        query.addBindValue(diff.language.value_or(QString()));
        query.addBindValue(diff.filename.value_or(QString()));
        query.addBindValue(orderIndex++);

        if (!query.exec()) {
            qWarning() << "[DiffsDatabase] Failed to save diff:" << query.lastError().text();
            sqlDb.rollback();
            return false;
        }
    }

    sqlDb.commit();
    return true;
}

QList<CachedDiff> DiffsDatabase::getDiffs(const QString& sessionId)
{
    QList<CachedDiff> result;
    QSqlQuery query(m_db);

    query.prepare("SELECT patch, language, filename FROM cached_diffs WHERE session_id = ? ORDER BY order_index");
    query.addBindValue(sessionId);

    if (!query.exec()) {
        qWarning() << "[DiffsDatabase] Failed to get diffs:" << query.lastError().text();
        return result;
    }

    while (query.next()) {
        CachedDiff diff;
        diff.patch = query.value(0).toString();
        QString lang = query.value(1).toString();
        QString file = query.value(2).toString();

        if (!lang.isEmpty()) diff.language = lang;
        if (!file.isEmpty()) diff.filename = file;

        result.append(diff);
    }

    return result;
}

bool DiffsDatabase::hasDiffs(const QString& sessionId)
{
    QSqlQuery query(m_db);
    query.prepare("SELECT 1 FROM cached_diffs WHERE session_id = ? LIMIT 1");
    query.addBindValue(sessionId);

    if (!query.exec()) {
        return false;
    }

    return query.next();
}

bool DiffsDatabase::deleteDiffs(const QString& sessionId)
{
    QSqlQuery query(m_db);
    query.prepare("DELETE FROM cached_diffs WHERE session_id = ?");
    query.addBindValue(sessionId);

    if (!query.exec()) {
        qWarning() << "[DiffsDatabase] Failed to delete diffs:" << query.lastError().text();
        return false;
    }

    return true;
}

bool DiffsDatabase::clearAllDiffs()
{
    QSqlQuery query(m_db);
    if (!query.exec("DELETE FROM cached_diffs")) {
        qWarning() << "[DiffsDatabase] Failed to clear all diffs:" << query.lastError().text();
        return false;
    }
    return true;
}

int DiffsDatabase::diffCount()
{
    QSqlQuery query(m_db);
    if (!query.exec("SELECT COUNT(*) FROM cached_diffs") || !query.next()) {
        return 0;
    }
    return query.value(0).toInt();
}

qint64 DiffsDatabase::databaseFileSize() const
{
    QFileInfo info(m_dbPath);
    return info.exists() ? info.size() : 0;
}

bool DiffsDatabase::runMigrations()
{
    int currentVersion = getCurrentVersion();

    constexpr int LATEST_VERSION = 1;

    for (int v = currentVersion + 1; v <= LATEST_VERSION; ++v) {
        if (!runMigration(v)) {
            qWarning() << "[DiffsDatabase] Migration" << v << "failed";
            return false;
        }
        if (!setSchemaVersion(v)) {
            return false;
        }
    }

    m_schemaVersion = LATEST_VERSION;
    return true;
}

bool DiffsDatabase::runMigration(int version)
{
    QSqlQuery query(m_db);

    switch (version) {
        case 1: {
            bool success = query.exec(R"(
                CREATE TABLE IF NOT EXISTS cached_diffs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    patch TEXT NOT NULL,
                    language TEXT,
                    filename TEXT,
                    order_index INTEGER DEFAULT 0
                )
            )");
            if (!success) {
                qWarning() << "[DiffsDatabase] Failed to create cached_diffs table:"
                           << query.lastError().text();
                return false;
            }

            query.exec("CREATE INDEX IF NOT EXISTS idx_diffs_session_id ON cached_diffs(session_id)");
            return true;
        }

        default:
            qWarning() << "[DiffsDatabase] Unknown migration version:" << version;
            return false;
    }
}

int DiffsDatabase::getCurrentVersion()
{
    QSqlQuery query(m_db);

    if (!query.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'")) {
        return 0;
    }

    if (!query.next()) {
        query.exec("CREATE TABLE schema_version (version INTEGER PRIMARY KEY)");
        query.exec("INSERT INTO schema_version (version) VALUES (0)");
        return 0;
    }

    query.exec("SELECT version FROM schema_version LIMIT 1");
    if (query.next()) {
        return query.value(0).toInt();
    }

    return 0;
}

bool DiffsDatabase::setSchemaVersion(int version)
{
    QSqlQuery query(m_db);
    query.prepare("UPDATE schema_version SET version = ?");
    query.addBindValue(version);

    if (!query.exec()) {
        qWarning() << "[DiffsDatabase] Failed to update schema version:" << query.lastError().text();
        return false;
    }

    return true;
}

} // namespace jules
