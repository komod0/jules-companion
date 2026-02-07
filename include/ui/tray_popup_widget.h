#pragma once

#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QListWidget>
#include <QLineEdit>
#include <QPropertyAnimation>
#include <QGraphicsDropShadowEffect>

namespace jules {

class SessionRepository;

/**
 * TrayPopupWidget - Floating popup panel that appears when clicking the system tray icon.
 * 
 * This replicates the macOS menu bar popup panel behavior:
 * - Positioned near the system tray icon
 * - Shows session list with status
 * - Has header with settings button
 * - Closes on click outside, ESC key, or focus loss
 * - Styled with rounded corners and shadow
 */
class TrayPopupWidget : public QWidget {
    Q_OBJECT
    Q_PROPERTY(qreal popupOpacity READ popupOpacity WRITE setPopupOpacity)

public:
    explicit TrayPopupWidget(SessionRepository* repository, QWidget* parent = nullptr);
    ~TrayPopupWidget() override;

    // Show popup near a specific screen position (typically tray icon location)
    void showNearPosition(const QPoint& globalPos);
    
    // Refresh session list from repository
    void refreshSessions();
    
    // Animation property
    qreal popupOpacity() const { return m_opacity; }
    void setPopupOpacity(qreal opacity);

signals:
    void sessionSelected(const QString& sessionId);
    void settingsRequested();
    void quitRequested();
    void newSessionRequested(const QString& prompt);

protected:
    void keyPressEvent(QKeyEvent* event) override;
    void focusOutEvent(QFocusEvent* event) override;
    bool event(QEvent* event) override;
    void paintEvent(QPaintEvent* event) override;
    void showEvent(QShowEvent* event) override;

private slots:
    void onSessionClicked(QListWidgetItem* item);
    void onSettingsClicked();
    void onNewSessionSubmit();

private:
    void setupUi();
    void setupStyling();
    void positionOnScreen(const QPoint& nearPos);
    void animateShow();
    void animateHide();
    
    // UI Components
    QVBoxLayout* m_mainLayout;
    
    // Header
    QWidget* m_headerWidget;
    QLabel* m_logoLabel;
    QLabel* m_titleLabel;
    QPushButton* m_minimizeBtn;
    QPushButton* m_settingsBtn;
    
    // New task input
    QWidget* m_inputWidget;
    QLineEdit* m_promptInput;
    QPushButton* m_submitBtn;
    
    // Session list
    QListWidget* m_sessionList;
    
    // Footer
    QWidget* m_footerWidget;
    QPushButton* m_quitBtn;
    
    // Data
    SessionRepository* m_repository;
    qreal m_opacity;
    
    // Animation
    QPropertyAnimation* m_fadeAnimation;
    
    // Constants (matching macOS AppConstants.Popover)
    static constexpr int POPUP_WIDTH = 400;
    static constexpr int POPUP_HEIGHT = 650;
    static constexpr int CORNER_RADIUS = 12;
};

} // namespace jules
