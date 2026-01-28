#include "ui/new_session_dialog.h"

#include <QHBoxLayout>
#include <QFormLayout>
#include <QMessageBox>
#include <QFont>
#include <QPushButton>

namespace jules {

const QString NewSessionDialog::SETTINGS_LAST_SOURCE = "NewSession/lastSourceId";
const QString NewSessionDialog::SETTINGS_LAST_BRANCHES = "NewSession/lastBranches";

NewSessionDialog::NewSessionDialog(const QList<Source>& sources, QWidget* parent)
    : QDialog(parent)
    , m_sources(sources)
    , m_sourceCombo(nullptr)
    , m_branchCombo(nullptr)
    , m_promptEdit(nullptr)
    , m_buttonBox(nullptr)
    , m_errorLabel(nullptr)
{
    setupUi();
    populateSources();
    loadPreferences();
    validateInput();
}

NewSessionDialog::~NewSessionDialog() = default;

void NewSessionDialog::setupUi() {
    setWindowTitle("New Session");
    setMinimumWidth(400);
    setModal(true);
    
    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->setSpacing(16);
    mainLayout->setContentsMargins(20, 20, 20, 20);
    
    auto* titleLabel = new QLabel("Create New Session", this);
    QFont titleFont = titleLabel->font();
    titleFont.setPointSize(titleFont.pointSize() + 4);
    titleFont.setBold(true);
    titleLabel->setFont(titleFont);
    
    auto* formLayout = new QFormLayout();
    formLayout->setSpacing(12);
    formLayout->setFieldGrowthPolicy(QFormLayout::ExpandingFieldsGrow);
    
    m_sourceCombo = new QComboBox(this);
    m_sourceCombo->setPlaceholderText("Select a repository...");
    connect(m_sourceCombo, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &NewSessionDialog::onSourceChanged);
    
    m_branchCombo = new QComboBox(this);
    m_branchCombo->setPlaceholderText("Select a branch...");
    
    m_promptEdit = new QTextEdit(this);
    m_promptEdit->setPlaceholderText("Describe what you want Jules to do...\n\nExample: Fix the authentication bug in login.py that causes users to be logged out unexpectedly.");
    m_promptEdit->setMinimumHeight(120);
    m_promptEdit->setMaximumHeight(200);
    connect(m_promptEdit, &QTextEdit::textChanged, 
            this, &NewSessionDialog::onPromptChanged);
    
    formLayout->addRow("Repository:", m_sourceCombo);
    formLayout->addRow("Branch:", m_branchCombo);
    formLayout->addRow("Task:", m_promptEdit);
    
    m_errorLabel = new QLabel(this);
    m_errorLabel->setStyleSheet("color: #ea4335; font-size: 12px;");
    m_errorLabel->hide();
    
    m_buttonBox = new QDialogButtonBox(
        QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
    m_buttonBox->button(QDialogButtonBox::Ok)->setText("Create Session");
    connect(m_buttonBox, &QDialogButtonBox::accepted, this, &NewSessionDialog::accept);
    connect(m_buttonBox, &QDialogButtonBox::rejected, this, &QDialog::reject);
    
    mainLayout->addWidget(titleLabel);
    mainLayout->addLayout(formLayout);
    mainLayout->addWidget(m_errorLabel);
    mainLayout->addStretch();
    mainLayout->addWidget(m_buttonBox);
}

void NewSessionDialog::populateSources() {
    m_sourceCombo->clear();
    for (const auto& source : m_sources) {
        m_sourceCombo->addItem(source.displayName(), source.id);
    }
}

void NewSessionDialog::populateBranches() {
    m_branchCombo->clear();
    
    int sourceIndex = m_sourceCombo->currentIndex();
    if (sourceIndex < 0 || sourceIndex >= m_sources.size()) {
        return;
    }
    
    const Source& source = m_sources[sourceIndex];
    if (!source.githubRepo.has_value()) {
        return;
    }
    
    const auto& branches = source.githubRepo->branches;
    for (const auto& branch : branches) {
        m_branchCombo->addItem(branch.displayName);
    }
    
    if (source.githubRepo->defaultBranch.has_value()) {
        QString defaultBranch = source.githubRepo->defaultBranch->displayName;
        int defaultIndex = m_branchCombo->findText(defaultBranch);
        if (defaultIndex >= 0) {
            m_branchCombo->setCurrentIndex(defaultIndex);
        }
    }
}

void NewSessionDialog::loadPreferences() {
    QSettings settings;
    
    QString lastSourceId = settings.value(SETTINGS_LAST_SOURCE).toString();
    if (!lastSourceId.isEmpty()) {
        int index = m_sourceCombo->findData(lastSourceId);
        if (index >= 0) {
            m_sourceCombo->setCurrentIndex(index);
        }
    }
}

int NewSessionDialog::sourceCount() const {
    return m_sourceCombo->count();
}

int NewSessionDialog::branchCount() const {
    return m_branchCombo->count();
}

int NewSessionDialog::currentSourceIndex() const {
    return m_sourceCombo->currentIndex();
}

void NewSessionDialog::selectSource(int index) {
    if (index >= 0 && index < m_sourceCombo->count()) {
        m_sourceCombo->setCurrentIndex(index);
    }
}

void NewSessionDialog::selectBranch(int index) {
    if (index >= 0 && index < m_branchCombo->count()) {
        m_branchCombo->setCurrentIndex(index);
    }
}

void NewSessionDialog::setPromptText(const QString& text) {
    m_promptEdit->setPlainText(text);
}

QString NewSessionDialog::promptText() const {
    return m_promptEdit->toPlainText().trimmed();
}

Source NewSessionDialog::selectedSource() const {
    int index = m_sourceCombo->currentIndex();
    if (index >= 0 && index < m_sources.size()) {
        return m_sources[index];
    }
    return Source();
}

QString NewSessionDialog::selectedBranch() const {
    return m_branchCombo->currentText();
}

bool NewSessionDialog::isValid() const {
    if (m_sourceCombo->currentIndex() < 0) {
        return false;
    }
    if (m_branchCombo->currentIndex() < 0) {
        return false;
    }
    if (promptText().isEmpty()) {
        return false;
    }
    return true;
}

void NewSessionDialog::savePreferences() {
    QSettings settings;
    
    int sourceIndex = m_sourceCombo->currentIndex();
    if (sourceIndex >= 0 && sourceIndex < m_sources.size()) {
        settings.setValue(SETTINGS_LAST_SOURCE, m_sources[sourceIndex].id);
        
        QVariantMap branchMap = settings.value(SETTINGS_LAST_BRANCHES).toMap();
        branchMap[m_sources[sourceIndex].id] = m_branchCombo->currentText();
        settings.setValue(SETTINGS_LAST_BRANCHES, branchMap);
    }
}

void NewSessionDialog::accept() {
    if (!isValid()) {
        return;
    }
    
    savePreferences();
    emit sessionRequested(selectedSource(), selectedBranch(), promptText());
    QDialog::accept();
}

void NewSessionDialog::onSourceChanged(int index) {
    Q_UNUSED(index);
    populateBranches();
    validateInput();
}

void NewSessionDialog::onPromptChanged() {
    validateInput();
}

void NewSessionDialog::validateInput() {
    bool valid = isValid();
    m_buttonBox->button(QDialogButtonBox::Ok)->setEnabled(valid);
    
    if (!valid && m_sourceCombo->count() == 0) {
        m_errorLabel->setText("No repositories available. Please add a source first.");
        m_errorLabel->show();
    } else if (!valid && promptText().isEmpty() && m_sourceCombo->currentIndex() >= 0) {
        m_errorLabel->setText("Please describe what you want Jules to do.");
        m_errorLabel->show();
    } else {
        m_errorLabel->hide();
    }
}

}
