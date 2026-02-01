#include "ui/flash_message_widget.h"
#include "rendering/wave_widget.h"

#include <QPainter>
#include <QVBoxLayout>
#include <QGraphicsOpacityEffect>

namespace jules {

FlashMessageWidget::FlashMessageWidget(QWidget* parent)
    : QWidget(parent)
    , m_backgroundColor(70, 130, 180)
    , m_textColor(255, 255, 255)
{
    setupUi();
    setVisible(false);
}

FlashMessageWidget::~FlashMessageWidget() = default;

void FlashMessageWidget::setupUi() {
    setFixedHeight(80);
    setAttribute(Qt::WA_TranslucentBackground);
    
    QVBoxLayout* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    
    QWidget* contentContainer = new QWidget(this);
    contentContainer->setFixedHeight(50);
    
    QHBoxLayout* contentLayout = new QHBoxLayout(contentContainer);
    contentLayout->setContentsMargins(20, 10, 20, 10);
    
    m_messageLabel = new QLabel(this);
    m_messageLabel->setAlignment(Qt::AlignCenter);
    m_messageLabel->setStyleSheet("font-size: 14px; font-weight: 500;");
    contentLayout->addWidget(m_messageLabel);
    
    layout->addWidget(contentContainer);
    
    m_waveWidget = new WaveWidget(this);
    m_waveWidget->setFixedHeight(30);
    m_waveWidget->setPreset(WavePreset::FlashMessage);
    m_waveWidget->setWaveEdge(WaveEdge::Bottom);
    layout->addWidget(m_waveWidget);
    
    m_dismissTimer = new QTimer(this);
    m_dismissTimer->setSingleShot(true);
    connect(m_dismissTimer, &QTimer::timeout, this, &FlashMessageWidget::startFadeOut);
    
    m_fadeAnimation = new QPropertyAnimation(this, "opacity", this);
    m_fadeAnimation->setDuration(300);
    connect(m_fadeAnimation, &QPropertyAnimation::finished, this, [this]() {
        if (m_opacity <= 0.01) {
            setVisible(false);
            emit dismissed();
        }
    });
}

void FlashMessageWidget::showMessage(const QString& message, FlashMessageType type, int durationMs) {
    m_messageLabel->setText(message);
    updateColors(type);
    
    m_opacity = 1.0;
    setVisible(true);
    update();
    
    m_waveWidget->reset();
    m_waveWidget->resume();
    
    if (durationMs > 0) {
        m_dismissTimer->start(durationMs);
    }
}

void FlashMessageWidget::hide() {
    m_dismissTimer->stop();
    startFadeOut();
}

qreal FlashMessageWidget::opacity() const {
    return m_opacity;
}

void FlashMessageWidget::setOpacity(qreal opacity) {
    m_opacity = opacity;
    update();
}

void FlashMessageWidget::updateColors(FlashMessageType type) {
    switch (type) {
        case FlashMessageType::Info:
            m_backgroundColor = QColor(70, 130, 180);
            m_textColor = QColor(255, 255, 255);
            break;
        case FlashMessageType::Success:
            m_backgroundColor = QColor(46, 160, 67);
            m_textColor = QColor(255, 255, 255);
            break;
        case FlashMessageType::Warning:
            m_backgroundColor = QColor(210, 153, 34);
            m_textColor = QColor(255, 255, 255);
            break;
        case FlashMessageType::Error:
            m_backgroundColor = QColor(207, 34, 46);
            m_textColor = QColor(255, 255, 255);
            break;
    }
    
    m_messageLabel->setStyleSheet(QString("font-size: 14px; font-weight: 500; color: %1;").arg(m_textColor.name()));
    m_waveWidget->setFillColor(m_backgroundColor.darker(110));
}

void FlashMessageWidget::startFadeOut() {
    m_fadeAnimation->setStartValue(m_opacity);
    m_fadeAnimation->setEndValue(0.0);
    m_fadeAnimation->start();
}

void FlashMessageWidget::paintEvent(QPaintEvent*) {
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setOpacity(m_opacity);
    
    QColor bgWithAlpha = m_backgroundColor;
    bgWithAlpha.setAlphaF(0.95);
    
    painter.setBrush(bgWithAlpha);
    painter.setPen(Qt::NoPen);
    
    int waveHeight = m_waveWidget ? m_waveWidget->height() : 30;
    QRect topRect(0, 0, width(), height() - waveHeight);
    painter.drawRoundedRect(topRect, 8, 8);
}

void FlashMessageWidget::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    if (m_waveWidget) {
        m_waveWidget->setViewportSize(width(), m_waveWidget->height(), devicePixelRatioF());
    }
}

}
