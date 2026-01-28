#pragma once

#include <QDialog>
#include <QComboBox>
#include <QTextEdit>
#include <QDialogButtonBox>
#include <QLabel>
#include <QVBoxLayout>
#include <QSettings>

#include "api/jules_api_client.h"

namespace jules {

class NewSessionDialog : public QDialog {
    Q_OBJECT

public:
    explicit NewSessionDialog(const QList<Source>& sources, QWidget* parent = nullptr);
    ~NewSessionDialog() override;

    int sourceCount() const;
    int branchCount() const;
    int currentSourceIndex() const;

    void selectSource(int index);
    void selectBranch(int index);
    void setPromptText(const QString& text);

    QString promptText() const;
    Source selectedSource() const;
    QString selectedBranch() const;

    bool isValid() const;
    void savePreferences();

signals:
    void sessionRequested(const Source& source, const QString& branch, const QString& prompt);

public slots:
    void accept() override;

private slots:
    void onSourceChanged(int index);
    void onPromptChanged();
    void validateInput();

private:
    void setupUi();
    void populateSources();
    void populateBranches();
    void loadPreferences();

    QList<Source> m_sources;
    QComboBox* m_sourceCombo;
    QComboBox* m_branchCombo;
    QTextEdit* m_promptEdit;
    QDialogButtonBox* m_buttonBox;
    QLabel* m_errorLabel;

    static const QString SETTINGS_LAST_SOURCE;
    static const QString SETTINGS_LAST_BRANCHES;
};

}
