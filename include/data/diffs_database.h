#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QSqlDatabase>

#include "api/jules_api_client.h"

namespace jules {

class DiffsDatabase : public QObject {
    Q_OBJECT

public:
    explicit DiffsDatabase(const QString& dataPath, QObject* parent = nullptr);
    ~DiffsDatabase() override;

    bool initialize();

    bool saveDiffs(const QString& sessionId, const QList<CachedDiff>& diffs);
    QList<CachedDiff> getDiffs(const QString& sessionId);
    bool hasDiffs(const QString& sessionId);
    bool deleteDiffs(const QString& sessionId);
    bool clearAllDiffs();
    int diffCount();
    qint64 databaseFileSize() const;

private:
    bool runMigrations();
    bool runMigration(int version);
    int getCurrentVersion();
    bool setSchemaVersion(int version);

    QString m_dataPath;
    QString m_dbPath;
    QSqlDatabase m_db;
    QString m_connectionName;
    int m_schemaVersion = 0;

    static int s_connectionCounter;
};

} // namespace jules
