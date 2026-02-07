#include "ui/feedback_dialog.h"

#include <QFormLayout>
#include <QFont>
#include <QPushButton>
#include <QDebug>

namespace jules {

FeedbackDialog::FeedbackDialog(QWidget* parent)
    : QDialog(parent)
    , m_typeCombo(nullptr)
    , m_textEdit(nullptr)
    , m_emailEdit(nullptr)
    , m_buttonBox(nullptr)
    , m_errorLabel(nullptr)
{
    setupUi();
    validateInput();
}

FeedbackDialog::~FeedbackDialog() = default;

void FeedbackDialog::setupUi() {
    setWindowTitle("Send Feedback");
    setMinimumWidth(400);
    setModal(true);

    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->setSpacing(16);
    mainLayout->setContentsMargins(20, 20, 20, 20);

    auto* titleLabel = new QLabel("Share your feedback about Jules", this);
    QFont titleFont = titleLabel->font();
    titleFont.setPointSize(titleFont.pointSize() + 4);
    titleFont.setBold(true);
    titleLabel->setFont(titleFont);

    auto* formLayout = new QFormLayout();
    formLayout->setSpacing(12);
    formLayout->setFieldGrowthPolicy(QFormLayout::ExpandingFieldsGrow);

    m_typeCombo = new QComboBox(this);
    m_typeCombo->addItem("Bug Report");
    m_typeCombo->addItem("Feature Request");
    m_typeCombo->addItem("General Feedback");

    m_textEdit = new QTextEdit(this);
    m_textEdit->setPlaceholderText("Describe your feedback in detail...");
    m_textEdit->setMinimumHeight(100);
    m_textEdit->setMaximumHeight(200);
    connect(m_textEdit, &QTextEdit::textChanged,
            this, &FeedbackDialog::onTextChanged);

    m_emailEdit = new QLineEdit(this);
    m_emailEdit->setPlaceholderText("Email (optional)");

    formLayout->addRow("Type:", m_typeCombo);
    formLayout->addRow("Feedback:", m_textEdit);
    formLayout->addRow("Email:", m_emailEdit);

    m_errorLabel = new QLabel(this);
    m_errorLabel->setStyleSheet("color: #ea4335; font-size: 12px;");
    m_errorLabel->hide();

    m_buttonBox = new QDialogButtonBox(
        QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
    m_buttonBox->button(QDialogButtonBox::Ok)->setText("Send");
    connect(m_buttonBox, &QDialogButtonBox::accepted, this, &FeedbackDialog::accept);
    connect(m_buttonBox, &QDialogButtonBox::rejected, this, &QDialog::reject);

    mainLayout->addWidget(titleLabel);
    mainLayout->addLayout(formLayout);
    mainLayout->addWidget(m_errorLabel);
    mainLayout->addStretch();
    mainLayout->addWidget(m_buttonBox);
}

QString FeedbackDialog::feedbackType() const {
    return m_typeCombo->currentText();
}

QString FeedbackDialog::feedbackText() const {
    return m_textEdit->toPlainText().trimmed();
}

QString FeedbackDialog::email() const {
    return m_emailEdit->text().trimmed();
}

bool FeedbackDialog::isValid() const {
    return !feedbackText().isEmpty();
}

void FeedbackDialog::accept() {
    if (!isValid()) {
        return;
    }

    qDebug() << "[FeedbackDialog] Submitted:" << feedbackType() << "-" << feedbackText().left(50);
    emit feedbackSubmitted(feedbackType(), feedbackText(), email());
    QDialog::accept();
}

void FeedbackDialog::onTextChanged() {
    validateInput();
}

void FeedbackDialog::validateInput() {
    bool valid = isValid();
    m_buttonBox->button(QDialogButtonBox::Ok)->setEnabled(valid);

    if (!valid && feedbackText().isEmpty()) {
        m_errorLabel->setText("Please enter your feedback before sending.");
        m_errorLabel->show();
    } else {
        m_errorLabel->hide();
    }
}

} // namespace jules
