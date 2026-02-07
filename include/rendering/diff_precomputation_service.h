#pragma once

#include "rendering/diff_renderer.h"
#include "api/jules_api_client.h"

#include <QObject>
#include <QMutex>
#include <QString>
#include <QList>

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace jules {

class DiffPrecomputationService : public QObject {
    Q_OBJECT

public:
    explicit DiffPrecomputationService(QObject* parent = nullptr);
    ~DiffPrecomputationService() override;

    DiffPrecomputationService(const DiffPrecomputationService&) = delete;
    DiffPrecomputationService& operator=(const DiffPrecomputationService&) = delete;

    void precomputeAll(const QString& sessionId, const QList<CachedDiff>& diffs);
    std::optional<std::vector<DiffSection>> getPrecomputed(const QString& sessionId);
    bool hasPrecomputed(const QString& sessionId);
    void invalidate(const QString& sessionId);
    void clear();
    void setCacheCapacity(int sessions);

signals:
    void precomputationComplete(const QString& sessionId);
    void precomputationFailed(const QString& sessionId, const QString& error);

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace jules
