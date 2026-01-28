#pragma once

#include <QObject>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QIcon>
#include <QPointer>

class QMainWindow;

namespace jules {

enum class TrayState {
    Idle,
    Active,
    NeedsAttention,
    Error
};

class SystemTray : public QObject {
    Q_OBJECT

public:
    explicit SystemTray(QObject* parent = nullptr);
    ~SystemTray() override;

    bool isAvailable() const;
    bool isVisible() const;

    TrayState state() const;
    void setState(TrayState state);

    QIcon currentIcon() const;

    QString toolTip() const;
    void setToolTip(const QString& tooltip);

    QMenu* contextMenu() const;
    QAction* showAction() const;
    QAction* settingsAction() const;
    QAction* quitAction() const;

    QMainWindow* targetWindow() const;
    void setTargetWindow(QMainWindow* window);

    void updateShowActionText();
    void toggleWindow();

    void simulateActivation(QSystemTrayIcon::ActivationReason reason);

public slots:
    void show();
    void hide();

signals:
    void stateChanged(TrayState state);
    void activated(QSystemTrayIcon::ActivationReason reason);
    void showWindowRequested();
    void settingsRequested();
    void quitRequested();

private slots:
    void onActivated(QSystemTrayIcon::ActivationReason reason);
    void onShowActionTriggered();
    void onTargetWindowDestroyed();

private:
    void setupIcons();
    void setupContextMenu();
    void updateIcon();
    void updateTooltip();

    QSystemTrayIcon* m_trayIcon;
    QMenu* m_contextMenu;
    QAction* m_showAction;
    QAction* m_settingsAction;
    QAction* m_quitAction;

    QPointer<QMainWindow> m_targetWindow;

    TrayState m_state = TrayState::Idle;
    QString m_customTooltip;

    QIcon m_idleIcon;
    QIcon m_activeIcon;
    QIcon m_attentionIcon;
    QIcon m_errorIcon;
};

}

Q_DECLARE_METATYPE(jules::TrayState)
