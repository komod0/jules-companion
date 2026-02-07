#pragma once

#include <QObject>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QIcon>
#include <QPointer>
#include <QTimer>
#include <QVector>

class QMainWindow;

namespace jules {

enum class TrayState {
    Idle,           // Default state, no active sessions
    Queued,         // Session queued - animated (loading)
    Planning,       // Session planning - animated (loading)
    Running,        // Session in progress - animated (running)
    NeedsAttention, // Awaiting plan approval or user feedback
    Paused,         // Session paused/review
    Failed,         // Session failed
    Error           // API error occurred
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
    void updateTheme(bool isDark);

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
    void popupRequested(const QPoint& globalPos);

private slots:
    void onActivated(QSystemTrayIcon::ActivationReason reason);
    void onShowActionTriggered();
    void onTargetWindowDestroyed();
    void onAnimationTick();

private:
    void setupIcons();
    void setupContextMenu();
    void setupAnimation();
    void updateIcon();
    void updateTooltip();
    void startAnimation();
    void stopAnimation();

    static QIcon loadTrayIcon(const QString& baseName);

    QSystemTrayIcon* m_trayIcon;
    QMenu* m_contextMenu;
    QAction* m_showAction;
    QAction* m_settingsAction;
    QAction* m_quitAction;

    QPointer<QMainWindow> m_targetWindow;

    TrayState m_state = TrayState::Idle;
    QString m_customTooltip;

    // Static icons (loaded from resources)
    QIcon m_idleIcon;
    QIcon m_attentionIcon;  // Warning state (awaiting approval/feedback)
    QIcon m_pausedIcon;     // Review/paused state
    QIcon m_failedIcon;     // Failed state
    QIcon m_errorIcon;      // API error state

    // Animation frames (loaded from resources)
    QVector<QIcon> m_loadingFrames;   // 5 frames for queued/planning
    QVector<QIcon> m_runningFrames;   // 6 frames for in progress

    // Animation state
    QTimer* m_animationTimer;
    int m_currentFrame = 0;
    bool m_isAnimating = false;
    bool m_isDark = true;

    // Animation sequences (frame indices for cycling)
    // Loading: 0->1->2->3->4->3->2->1->0 (bouncing)
    static const QVector<int> s_loadingSequence;
    // Running: 0->1->2->3->4->5 (smooth loop)
    static const QVector<int> s_runningSequence;
};

}

Q_DECLARE_METATYPE(jules::TrayState)
