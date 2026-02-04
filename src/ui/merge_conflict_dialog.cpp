#include "ui/merge_conflict_dialog.h"
#include "ui/app_colors.h"

#include <QFont>
#include <QRegularExpression>
#include <QMessageBox>

namespace jules {

// ConflictFile implementation
bool ConflictFile::allResolved() const {
    for (const auto& conflict : conflicts) {
        if (!conflict.resolved) {
            return false;
        }
    }
    return !conflicts.empty();
}

QString ConflictFile::getResolvedContent() const {
    if (!allResolved()) {
        return originalContent;
    }
    
    QString result = originalContent;
    
    // Apply resolutions in reverse order to maintain line positions
    for (int i = static_cast<int>(conflicts.size()) - 1; i >= 0; --i) {
        const auto& conflict = conflicts[i];
        QString replacement;
        
        switch (conflict.resolution) {
            case ConflictRegion::Resolution::Ours:
                replacement = conflict.oursContent;
                break;
            case ConflictRegion::Resolution::Theirs:
                replacement = conflict.theirsContent;
                break;
            case ConflictRegion::Resolution::Both:
                replacement = conflict.oursContent + "\n" + conflict.theirsContent;
                break;
            default:
                continue;
        }
        
        // Find and replace the conflict markers in the content
        QStringList lines = result.split('\n');
        if (conflict.startLine >= 0 && conflict.endLine < lines.size()) {
            QStringList newLines;
            for (int j = 0; j < lines.size(); ++j) {
                if (j < conflict.startLine || j > conflict.endLine) {
                    newLines.append(lines[j]);
                } else if (j == conflict.startLine) {
                    newLines.append(replacement.split('\n'));
                }
            }
            result = newLines.join('\n');
        }
    }
    
    return result;
}

// MergeConflictDialog implementation
MergeConflictDialog::MergeConflictDialog(QWidget* parent)
    : QDialog(parent)
    , m_mainSplitter(nullptr)
    , m_fileList(nullptr)
    , m_conflictList(nullptr)
    , m_contentView(nullptr)
    , m_statusLabel(nullptr)
    , m_acceptOursBtn(nullptr)
    , m_acceptTheirsBtn(nullptr)
    , m_acceptBothBtn(nullptr)
    , m_completeBtn(nullptr)
    , m_cancelBtn(nullptr)
{
    setupUi();
    setWindowTitle("Merge Conflicts");
    resize(1000, 700);
}

MergeConflictDialog::~MergeConflictDialog() = default;

void MergeConflictDialog::setupUi() {
    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);
    mainLayout->setSpacing(0);
    
    bool isDark = palette().window().color().lightness() < 128;
    
    // Header with title and status
    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(16, 12, 16, 12);
    
    auto* titleLabel = new QLabel("Merge Conflicts", header);
    QFont titleFont = titleLabel->font();
    titleFont.setPointSize(16);
    titleFont.setBold(true);
    titleLabel->setFont(titleFont);
    
    m_statusLabel = new QLabel("No files with conflicts", header);
    m_statusLabel->setStyleSheet(QString("color: %1;").arg(
        AppColors::textSecondary(isDark).name()));
    
    headerLayout->addWidget(titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(m_statusLabel);
    
    // Main splitter with file list and content
    m_mainSplitter = new QSplitter(Qt::Horizontal, this);
    
    // Left panel: File list and conflict list
    auto* leftPanel = new QWidget(m_mainSplitter);
    auto* leftLayout = new QVBoxLayout(leftPanel);
    leftLayout->setContentsMargins(8, 8, 8, 8);
    leftLayout->setSpacing(8);
    
    auto* filesLabel = new QLabel("Files with Conflicts", leftPanel);
    QFont labelFont = filesLabel->font();
    labelFont.setBold(true);
    filesLabel->setFont(labelFont);
    
    m_fileList = new QListWidget(leftPanel);
    m_fileList->setMaximumHeight(200);
    connect(m_fileList, &QListWidget::currentRowChanged,
            this, &MergeConflictDialog::onFileSelected);
    
    auto* conflictsLabel = new QLabel("Conflicts in File", leftPanel);
    conflictsLabel->setFont(labelFont);
    
    m_conflictList = new QListWidget(leftPanel);
    connect(m_conflictList, &QListWidget::currentRowChanged,
            this, &MergeConflictDialog::onConflictSelected);
    
    leftLayout->addWidget(filesLabel);
    leftLayout->addWidget(m_fileList);
    leftLayout->addWidget(conflictsLabel);
    leftLayout->addWidget(m_conflictList, 1);
    
    // Right panel: Content view with action buttons
    auto* rightPanel = new QWidget(m_mainSplitter);
    auto* rightLayout = new QVBoxLayout(rightPanel);
    rightLayout->setContentsMargins(8, 8, 8, 8);
    rightLayout->setSpacing(8);
    
    auto* contentLabel = new QLabel("Conflict Content", rightPanel);
    contentLabel->setFont(labelFont);
    
    m_contentView = new QTextEdit(rightPanel);
    m_contentView->setReadOnly(true);
    m_contentView->setFont(QFont("monospace", 11));
    m_contentView->setStyleSheet(R"(
        QTextEdit {
            background-color: palette(base);
            border: 1px solid palette(mid);
            border-radius: 4px;
        }
    )");
    
    // Action buttons for resolving conflicts
    auto* actionRow = new QHBoxLayout();
    actionRow->setSpacing(8);
    
    m_acceptOursBtn = new QPushButton("Accept Ours (HEAD)", rightPanel);
    m_acceptOursBtn->setStyleSheet(R"(
        QPushButton {
            background-color: #22c55e;
            color: white;
            border: none;
            border-radius: 6px;
            padding: 8px 16px;
            font-weight: 500;
        }
        QPushButton:hover { background-color: #16a34a; }
        QPushButton:disabled { background-color: #9ca3af; }
    )");
    connect(m_acceptOursBtn, &QPushButton::clicked,
            this, &MergeConflictDialog::onAcceptOurs);
    
    m_acceptTheirsBtn = new QPushButton("Accept Theirs", rightPanel);
    m_acceptTheirsBtn->setStyleSheet(R"(
        QPushButton {
            background-color: #3b82f6;
            color: white;
            border: none;
            border-radius: 6px;
            padding: 8px 16px;
            font-weight: 500;
        }
        QPushButton:hover { background-color: #2563eb; }
        QPushButton:disabled { background-color: #9ca3af; }
    )");
    connect(m_acceptTheirsBtn, &QPushButton::clicked,
            this, &MergeConflictDialog::onAcceptTheirs);
    
    m_acceptBothBtn = new QPushButton("Accept Both", rightPanel);
    m_acceptBothBtn->setStyleSheet(R"(
        QPushButton {
            background-color: #8b5cf6;
            color: white;
            border: none;
            border-radius: 6px;
            padding: 8px 16px;
            font-weight: 500;
        }
        QPushButton:hover { background-color: #7c3aed; }
        QPushButton:disabled { background-color: #9ca3af; }
    )");
    connect(m_acceptBothBtn, &QPushButton::clicked,
            this, &MergeConflictDialog::onAcceptBoth);
    
    actionRow->addWidget(m_acceptOursBtn);
    actionRow->addWidget(m_acceptTheirsBtn);
    actionRow->addWidget(m_acceptBothBtn);
    actionRow->addStretch();
    
    rightLayout->addWidget(contentLabel);
    rightLayout->addWidget(m_contentView, 1);
    rightLayout->addLayout(actionRow);
    
    m_mainSplitter->addWidget(leftPanel);
    m_mainSplitter->addWidget(rightPanel);
    m_mainSplitter->setSizes({300, 700});
    
    // Bottom button row
    auto* buttonRow = new QHBoxLayout();
    buttonRow->setContentsMargins(16, 12, 16, 12);
    buttonRow->setSpacing(12);
    
    m_cancelBtn = new QPushButton("Cancel", this);
    m_cancelBtn->setStyleSheet(R"(
        QPushButton {
            background-color: transparent;
            border: 1px solid palette(mid);
            border-radius: 6px;
            padding: 10px 24px;
        }
        QPushButton:hover {
            background-color: rgba(128, 128, 128, 0.1);
        }
    )");
    connect(m_cancelBtn, &QPushButton::clicked, [this]() {
        emit mergeCancelled();
        reject();
    });
    
    m_completeBtn = new QPushButton("Complete Merge", this);
    m_completeBtn->setEnabled(false);
    m_completeBtn->setStyleSheet(R"(
        QPushButton {
            background-color: #22c55e;
            color: white;
            border: none;
            border-radius: 6px;
            padding: 10px 24px;
            font-weight: 600;
        }
        QPushButton:hover { background-color: #16a34a; }
        QPushButton:disabled { background-color: #9ca3af; color: #e5e7eb; }
    )");
    connect(m_completeBtn, &QPushButton::clicked,
            this, &MergeConflictDialog::onCompleteMerge);
    
    buttonRow->addStretch();
    buttonRow->addWidget(m_cancelBtn);
    buttonRow->addWidget(m_completeBtn);
    
    mainLayout->addWidget(header);
    mainLayout->addWidget(m_mainSplitter, 1);
    mainLayout->addLayout(buttonRow);
    
    updateButtonStates();
}

void MergeConflictDialog::setConflictFiles(const std::vector<ConflictFile>& files) {
    m_files = files;
    
    // Parse conflicts from content for each file
    for (auto& file : m_files) {
        parseConflictsFromContent(file);
    }
    
    populateFileList();
    updateButtonStates();
    
    if (!m_files.empty()) {
        m_fileList->setCurrentRow(0);
    }
}

void MergeConflictDialog::addConflictFile(const ConflictFile& file) {
    ConflictFile fileCopy = file;
    parseConflictsFromContent(fileCopy);
    m_files.push_back(fileCopy);
    populateFileList();
    updateButtonStates();
}

void MergeConflictDialog::clear() {
    m_files.clear();
    m_currentFileIndex = -1;
    m_currentConflictIndex = -1;
    m_fileList->clear();
    m_conflictList->clear();
    m_contentView->clear();
    updateButtonStates();
}

int MergeConflictDialog::fileCount() const {
    return static_cast<int>(m_files.size());
}

int MergeConflictDialog::unresolvedCount() const {
    int count = 0;
    for (const auto& file : m_files) {
        for (const auto& conflict : file.conflicts) {
            if (!conflict.resolved) {
                count++;
            }
        }
    }
    return count;
}

bool MergeConflictDialog::allResolved() const {
    for (const auto& file : m_files) {
        if (!file.allResolved()) {
            return false;
        }
    }
    return !m_files.empty();
}

std::vector<ConflictFile> MergeConflictDialog::getResolvedFiles() const {
    return m_files;
}

void MergeConflictDialog::onFileSelected(int index) {
    if (index < 0 || index >= static_cast<int>(m_files.size())) {
        m_currentFileIndex = -1;
        m_conflictList->clear();
        m_contentView->clear();
        return;
    }
    
    m_currentFileIndex = index;
    populateConflictList();
    
    if (!m_files[index].conflicts.empty()) {
        m_conflictList->setCurrentRow(0);
    }
}

void MergeConflictDialog::onConflictSelected(int index) {
    displayConflict(index);
}

void MergeConflictDialog::onAcceptOurs() {
    if (m_currentFileIndex < 0 || m_currentConflictIndex < 0) {
        return;
    }
    
    auto& conflict = m_files[m_currentFileIndex].conflicts[m_currentConflictIndex];
    conflict.resolution = ConflictRegion::Resolution::Ours;
    conflict.resolved = true;
    
    updateConflictContent();
    updateButtonStates();
    populateConflictList();
    
    emit conflictResolved(m_files[m_currentFileIndex].path);
    
    if (allResolved()) {
        emit allConflictsResolved();
    }
}

void MergeConflictDialog::onAcceptTheirs() {
    if (m_currentFileIndex < 0 || m_currentConflictIndex < 0) {
        return;
    }
    
    auto& conflict = m_files[m_currentFileIndex].conflicts[m_currentConflictIndex];
    conflict.resolution = ConflictRegion::Resolution::Theirs;
    conflict.resolved = true;
    
    updateConflictContent();
    updateButtonStates();
    populateConflictList();
    
    emit conflictResolved(m_files[m_currentFileIndex].path);
    
    if (allResolved()) {
        emit allConflictsResolved();
    }
}

void MergeConflictDialog::onAcceptBoth() {
    if (m_currentFileIndex < 0 || m_currentConflictIndex < 0) {
        return;
    }
    
    auto& conflict = m_files[m_currentFileIndex].conflicts[m_currentConflictIndex];
    conflict.resolution = ConflictRegion::Resolution::Both;
    conflict.resolved = true;
    
    updateConflictContent();
    updateButtonStates();
    populateConflictList();
    
    emit conflictResolved(m_files[m_currentFileIndex].path);
    
    if (allResolved()) {
        emit allConflictsResolved();
    }
}

void MergeConflictDialog::onCompleteMerge() {
    if (!allResolved()) {
        QMessageBox::warning(this, "Unresolved Conflicts",
            "Please resolve all conflicts before completing the merge.");
        return;
    }
    
    emit mergeCompleted();
    accept();
}

void MergeConflictDialog::populateFileList() {
    m_fileList->clear();
    
    for (const auto& file : m_files) {
        int unresolvedInFile = 0;
        for (const auto& conflict : file.conflicts) {
            if (!conflict.resolved) {
                unresolvedInFile++;
            }
        }
        
        QString displayText = file.path;
        if (displayText.contains('/')) {
            displayText = displayText.section('/', -1);
        }
        
        QString statusIcon = file.allResolved() ? "✓ " : "⚠ ";
        QString itemText = QString("%1%2 (%3 conflict%4)")
            .arg(statusIcon)
            .arg(displayText)
            .arg(file.conflicts.size())
            .arg(file.conflicts.size() != 1 ? "s" : "");
        
        auto* item = new QListWidgetItem(itemText);
        item->setToolTip(file.path);
        
        if (file.allResolved()) {
            item->setForeground(QColor(34, 197, 94));  // Green
        } else {
            item->setForeground(QColor(239, 68, 68));  // Red
        }
        
        m_fileList->addItem(item);
    }
    
    // Update status label
    int totalConflicts = 0;
    int resolvedConflicts = 0;
    for (const auto& file : m_files) {
        totalConflicts += static_cast<int>(file.conflicts.size());
        for (const auto& conflict : file.conflicts) {
            if (conflict.resolved) {
                resolvedConflicts++;
            }
        }
    }
    
    m_statusLabel->setText(QString("%1 file%2, %3/%4 conflicts resolved")
        .arg(m_files.size())
        .arg(m_files.size() != 1 ? "s" : "")
        .arg(resolvedConflicts)
        .arg(totalConflicts));
}

void MergeConflictDialog::populateConflictList() {
    m_conflictList->clear();
    
    if (m_currentFileIndex < 0 || m_currentFileIndex >= static_cast<int>(m_files.size())) {
        return;
    }
    
    const auto& file = m_files[m_currentFileIndex];
    int conflictNum = 1;
    
    for (const auto& conflict : file.conflicts) {
        QString statusIcon = conflict.resolved ? "✓ " : "• ";
        QString resolutionText;
        
        if (conflict.resolved) {
            switch (conflict.resolution) {
                case ConflictRegion::Resolution::Ours:
                    resolutionText = " (Ours)";
                    break;
                case ConflictRegion::Resolution::Theirs:
                    resolutionText = " (Theirs)";
                    break;
                case ConflictRegion::Resolution::Both:
                    resolutionText = " (Both)";
                    break;
                default:
                    break;
            }
        }
        
        QString itemText = QString("%1Conflict %2 (lines %3-%4)%5")
            .arg(statusIcon)
            .arg(conflictNum++)
            .arg(conflict.startLine + 1)
            .arg(conflict.endLine + 1)
            .arg(resolutionText);
        
        auto* item = new QListWidgetItem(itemText);
        
        if (conflict.resolved) {
            item->setForeground(QColor(34, 197, 94));  // Green
        }
        
        m_conflictList->addItem(item);
    }
}

void MergeConflictDialog::displayConflict(int conflictIndex) {
    if (m_currentFileIndex < 0 || 
        m_currentFileIndex >= static_cast<int>(m_files.size()) ||
        conflictIndex < 0 ||
        conflictIndex >= static_cast<int>(m_files[m_currentFileIndex].conflicts.size())) {
        m_currentConflictIndex = -1;
        m_contentView->clear();
        updateButtonStates();
        return;
    }
    
    m_currentConflictIndex = conflictIndex;
    updateConflictContent();
    updateButtonStates();
}

void MergeConflictDialog::updateConflictContent() {
    if (m_currentFileIndex < 0 || m_currentConflictIndex < 0) {
        return;
    }
    
    const auto& conflict = m_files[m_currentFileIndex].conflicts[m_currentConflictIndex];
    
    QString html;
    html += "<div style='font-family: monospace; font-size: 11pt;'>";
    
    // Show ours section
    html += "<div style='background-color: rgba(34, 197, 94, 0.2); padding: 8px; margin-bottom: 4px; border-radius: 4px;'>";
    html += "<strong style='color: #22c55e;'><<<<<<< HEAD (Ours)</strong><br>";
    html += conflict.oursContent.toHtmlEscaped().replace("\n", "<br>");
    html += "</div>";
    
    // Show separator
    html += "<div style='text-align: center; color: #6b7280; margin: 8px 0;'>=======</div>";
    
    // Show theirs section
    html += "<div style='background-color: rgba(59, 130, 246, 0.2); padding: 8px; margin-top: 4px; border-radius: 4px;'>";
    html += conflict.theirsContent.toHtmlEscaped().replace("\n", "<br>");
    html += "<br><strong style='color: #3b82f6;'>>>>>>>> (Theirs)</strong>";
    html += "</div>";
    
    if (conflict.resolved) {
        html += "<div style='margin-top: 12px; padding: 8px; background-color: rgba(34, 197, 94, 0.1); border-radius: 4px;'>";
        html += "<strong style='color: #22c55e;'>✓ Resolved: ";
        switch (conflict.resolution) {
            case ConflictRegion::Resolution::Ours:
                html += "Accepted Ours";
                break;
            case ConflictRegion::Resolution::Theirs:
                html += "Accepted Theirs";
                break;
            case ConflictRegion::Resolution::Both:
                html += "Accepted Both";
                break;
            default:
                break;
        }
        html += "</strong></div>";
    }
    
    html += "</div>";
    
    m_contentView->setHtml(html);
}

void MergeConflictDialog::updateButtonStates() {
    bool hasConflictSelected = (m_currentFileIndex >= 0 && m_currentConflictIndex >= 0);
    bool currentResolved = false;
    
    if (hasConflictSelected && 
        m_currentConflictIndex < static_cast<int>(m_files[m_currentFileIndex].conflicts.size())) {
        currentResolved = m_files[m_currentFileIndex].conflicts[m_currentConflictIndex].resolved;
    }
    
    m_acceptOursBtn->setEnabled(hasConflictSelected && !currentResolved);
    m_acceptTheirsBtn->setEnabled(hasConflictSelected && !currentResolved);
    m_acceptBothBtn->setEnabled(hasConflictSelected && !currentResolved);
    m_completeBtn->setEnabled(allResolved());
}

void MergeConflictDialog::parseConflictsFromContent(ConflictFile& file) {
    file.conflicts.clear();
    
    QStringList lines = file.originalContent.split('\n');
    
    int i = 0;
    while (i < lines.size()) {
        // Look for conflict start marker
        if (lines[i].startsWith("<<<<<<< ")) {
            ConflictRegion region;
            region.startLine = i;
            
            // Collect "ours" content
            QStringList oursLines;
            i++;
            while (i < lines.size() && !lines[i].startsWith("=======")) {
                oursLines.append(lines[i]);
                i++;
            }
            region.oursContent = oursLines.join('\n');
            
            // Skip separator
            if (i < lines.size() && lines[i].startsWith("=======")) {
                i++;
            }
            
            // Collect "theirs" content
            QStringList theirsLines;
            while (i < lines.size() && !lines[i].startsWith(">>>>>>> ")) {
                theirsLines.append(lines[i]);
                i++;
            }
            region.theirsContent = theirsLines.join('\n');
            
            // Mark end of conflict
            if (i < lines.size() && lines[i].startsWith(">>>>>>> ")) {
                region.endLine = i;
                i++;
            } else {
                region.endLine = i;
            }
            
            file.conflicts.push_back(region);
        } else {
            i++;
        }
    }
}

QString MergeConflictDialog::highlightConflictMarkers(const QString& content) const {
    QString result = content.toHtmlEscaped();
    
    // Highlight conflict markers
    result.replace(QRegularExpression("(&lt;&lt;&lt;&lt;&lt;&lt;&lt;[^\n]*)"), 
                   "<span style='color: #22c55e; font-weight: bold;'>\\1</span>");
    result.replace("=======", 
                   "<span style='color: #f59e0b; font-weight: bold;'>=======</span>");
    result.replace(QRegularExpression("(&gt;&gt;&gt;&gt;&gt;&gt;&gt;[^\n]*)"), 
                   "<span style='color: #3b82f6; font-weight: bold;'>\\1</span>");
    
    result.replace("\n", "<br>");
    return result;
}

} // namespace jules
