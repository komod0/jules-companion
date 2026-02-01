#pragma once

#include <QWidget>
#include <QLabel>
#include <QTimer>
#include <QPropertyAnimation>

namespace jules {

class WaveWidget;

enum class FlashMessageType {
    Info,
    Success,
    Warning,
    Error
};

class FlashMessageWidget : public QWidget {
    Q_OBJECT
    Q_PROPERTY(qreal opacity READ opacity WRITE setOpacity)

public:
    explicit FlashMessageWidget(QWidget* parent = nullptr);
    ~FlashMessageWidget() override;

    void showMessage(const QString& message, FlashMessageType type = FlashMessageType::Info, int durationMs = 3000);
    void hide();
    
    qreal opacity() const;
    void setOpacity(qreal opacity);

signals:
    void dismissed();

protected:
    void paintEvent(QPaintEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    void setupUi();
    void updateColors(FlashMessageType type);
    void startFadeOut();
    
    QLabel* m_messageLabel = nullptr;
    WaveWidget* m_waveWidget = nullptr;
    QTimer* m_dismissTimer = nullptr;
    QPropertyAnimation* m_fadeAnimation = nullptr;
    
    qreal m_opacity = 1.0;
    QColor m_backgroundColor;
    QColor m_textColor;
};

}
