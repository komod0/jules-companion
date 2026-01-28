#pragma once

#include <QObject>
#include <QString>
#include <QSqlDatabase>

#include <memory>

namespace jules {

class Database : public QObject {
    Q_OBJECT

public:
    explicit Database(const QString& dataPath, QObject* parent = nullptr);
    ~Database() override;

    bool initialize();
    
    QSqlDatabase database() const;
    int schemaVersion() const;
    
    QString databasePath() const;
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

}
