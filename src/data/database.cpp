#include "data/database.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSqlQuery>
#include <QSqlError>
#include <QDebug>

namespace jules {

int Database::s_connectionCounter = 0;

Database::Database(const QString& dataPath, QObject* parent)
    : QObject(parent)
    , m_dataPath(dataPath)
    , m_connectionName(QString("jules_db_%1").arg(++s_connectionCounter))
{
    m_dbPath = QDir(m_dataPath).filePath("jules.db");
}

Database::~Database()
{
    if (m_db.isOpen()) {
        m_db.close();
    }
    QSqlDatabase::removeDatabase(m_connectionName);
}

bool Database::initialize()
{
    QDir dir(m_dataPath);
    if (!dir.exists()) {
        if (!dir.mkpath(".")) {
            qWarning() << "Failed to create data directory:" << m_dataPath;
            return false;
        }
    }

    m_db = QSqlDatabase::addDatabase("QSQLITE", m_connectionName);
    m_db.setDatabaseName(m_dbPath);
    
    if (!m_db.open()) {
        qWarning() << "Failed to open database:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    query.exec("PRAGMA journal_mode=WAL");
    query.exec("PRAGMA foreign_keys=ON");
    query.exec("PRAGMA synchronous=NORMAL");

    return runMigrations();
}

QSqlDatabase Database::database() const
{
    return m_db;
}

int Database::schemaVersion() const
{
    return m_schemaVersion;
}

QString Database::databasePath() const
{
    return m_dbPath;
}

qint64 Database::databaseFileSize() const
{
    QFileInfo info(m_dbPath);
    return info.exists() ? info.size() : 0;
}

bool Database::runMigrations()
{
    int currentVersion = getCurrentVersion();
    
    constexpr int LATEST_VERSION = 2;
    
    for (int v = currentVersion + 1; v <= LATEST_VERSION; ++v) {
        if (!runMigration(v)) {
            qWarning() << "Migration" << v << "failed";
            return false;
        }
        if (!setSchemaVersion(v)) {
            return false;
        }
    }
    
    m_schemaVersion = LATEST_VERSION;
    return true;
}

bool Database::runMigration(int version)
{
    QSqlQuery query(m_db);
    
    switch (version) {
        case 1: {
            bool success = query.exec(R"(
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    json TEXT NOT NULL,
                    create_time TEXT,
                    update_time TEXT,
                    state TEXT,
                    has_cached_diffs INTEGER DEFAULT 0,
                    last_activity_poll_time TEXT,
                    viewed_post_completion_at TEXT
                )
            )");
            if (!success) {
                qWarning() << "Failed to create sessions table:" << query.lastError().text();
                return false;
            }

            success = query.exec(R"(
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
                qWarning() << "Failed to create cached_diffs table:" << query.lastError().text();
                return false;
            }

            query.exec("CREATE INDEX IF NOT EXISTS idx_sessions_state ON sessions(state)");
            query.exec("CREATE INDEX IF NOT EXISTS idx_sessions_create_time ON sessions(create_time)");
            query.exec("CREATE INDEX IF NOT EXISTS idx_cached_diffs_session_id ON cached_diffs(session_id)");
            
            return true;
        }
        
        case 2: {
            query.exec("CREATE INDEX IF NOT EXISTS idx_sessions_state_create_time ON sessions(state, create_time)");
            return true;
        }
        
        default:
            qWarning() << "Unknown migration version:" << version;
            return false;
    }
}

int Database::getCurrentVersion()
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

bool Database::setSchemaVersion(int version)
{
    QSqlQuery query(m_db);
    query.prepare("UPDATE schema_version SET version = ?");
    query.addBindValue(version);
    
    if (!query.exec()) {
        qWarning() << "Failed to update schema version:" << query.lastError().text();
        return false;
    }
    
    return true;
}

}
