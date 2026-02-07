#pragma once

#include <QDialog>
#include <QComboBox>
#include <QTextEdit>
#include <QLineEdit>
#include <QDialogButtonBox>
#include <QLabel>
#include <QVBoxLayout>

namespace jules {

class FeedbackDialog : public QDialog {
    Q_OBJECT

public:
    explicit FeedbackDialog(QWidget* parent = nullptr);
    ~FeedbackDialog() override;

    QString feedbackType() const;
    QString feedbackText() const;
    QString email() const;
    bool isValid() const;

signals:
    void feedbackSubmitted(const QString& type, const QString& text, const QString& email);

public slots:
    void accept() override;

private slots:
    void onTextChanged();
    void validateInput();

private:
    void setupUi();

    QComboBox* m_typeCombo;
    QTextEdit* m_textEdit;
    QLineEdit* m_emailEdit;
    QDialogButtonBox* m_buttonBox;
    QLabel* m_errorLabel;
};

} // namespace jules
