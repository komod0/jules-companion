#pragma once

#include <QDialog>
#include <QListWidget>
#include <QTextEdit>
#include <QSplitter>
#include <QPushButton>
#include <QLabel>
#include <QVBoxLayout>
#include <QHBoxLayout>

#include <vector>
#include <optional>

namespace jules {

/**
 * Represents a single conflict region within a file
 */
struct ConflictRegion {
    int startLine;
    int endLine;
    QString oursContent;    // Content from our branch (HEAD)
    QString theirsContent;  // Content from their branch
    QString baseContent;    // Common ancestor content (if available)
    bool resolved = false;
    enum class Resolution { None, Ours, Theirs, Both } resolution = Resolution::None;
};

/**
 * Represents a file containing merge conflicts
 */
struct ConflictFile {
    QString path;
    QString originalContent;
    QString language;
    std::vector<ConflictRegion> conflicts;
    bool allResolved() const;
    QString getResolvedContent() const;
};

/**
 * Dialog for viewing and resolving merge conflicts.
 * Provides a split view with file list and conflict content.
 */
class MergeConflictDialog : public QDialog {
    Q_OBJECT

public:
    explicit MergeConflictDialog(QWidget* parent = nullptr);
    ~MergeConflictDialog() override;

    void setConflictFiles(const std::vector<ConflictFile>& files);
    void addConflictFile(const ConflictFile& file);
    void clear();

    int fileCount() const;
    int unresolvedCount() const;
    bool allResolved() const;

    std::vector<ConflictFile> getResolvedFiles() const;

signals:
    void conflictResolved(const QString& filePath);
    void allConflictsResolved();
    void mergeCompleted();
    void mergeCancelled();

private slots:
    void onFileSelected(int index);
    void onConflictSelected(int index);
    void onAcceptOurs();
    void onAcceptTheirs();
    void onAcceptBoth();
    void onCompleteMerge();

private:
    void setupUi();
    void populateFileList();
    void populateConflictList();
    void displayConflict(int conflictIndex);
    void updateConflictContent();
    void updateButtonStates();
    void parseConflictsFromContent(ConflictFile& file);
    QString highlightConflictMarkers(const QString& content) const;

    std::vector<ConflictFile> m_files;
    int m_currentFileIndex = -1;
    int m_currentConflictIndex = -1;

    // UI components
    QSplitter* m_mainSplitter;
    QListWidget* m_fileList;
    QListWidget* m_conflictList;
    QTextEdit* m_contentView;
    QLabel* m_statusLabel;
    QPushButton* m_acceptOursBtn;
    QPushButton* m_acceptTheirsBtn;
    QPushButton* m_acceptBothBtn;
    QPushButton* m_completeBtn;
    QPushButton* m_cancelBtn;
};

} // namespace jules
