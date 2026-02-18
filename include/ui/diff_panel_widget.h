#pragma once

#include "rendering/diff_renderer.h"
#include "rendering/font_atlas.h"
#include "api/jules_api_client.h"

#include <QOpenGLWidget>
#include <QOpenGLFunctions_4_3_Core>
#include <QOpenGLShaderProgram>
#include <QOpenGLBuffer>
#include <QOpenGLVertexArrayObject>
#include <QEvent>
#include <QWheelEvent>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QContextMenuEvent>
#include <QTimer>
#include <QElapsedTimer>
#include <QScrollBar>

#include <memory>
#include <vector>

namespace jules {

class DiffPanelWidget : public QOpenGLWidget, protected QOpenGLFunctions_4_3_Core {
    Q_OBJECT

public:
    explicit DiffPanelWidget(QWidget* parent = nullptr);
    ~DiffPanelWidget() override;

    void setDiffs(const QList<CachedDiff>& diffs);

    // Loading state management
    void setLoading(bool loading);
    bool isLoading() const { return m_isLoading; }

    // Adaptive memory management
    void releaseResources();

    // Theme support — call when app theme changes
    void updateTheme();
    void updateDarkMode(bool isDark); // Convenience wrapper

signals:
    void openglFailed(const QString& reason);

protected:
    void initializeGL() override;
    void resizeGL(int w, int h) override;
    void paintGL() override;
    void wheelEvent(QWheelEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void contextMenuEvent(QContextMenuEvent* event) override;

private:
    QString sectionFilenameAt(const QPoint& pos) const;
    TextPosition pixelToTextPosition(const QPoint& pos) const;
    bool loadShaders();
    void setupBuffers();
    void renderLoadingSpinner();
    void renderEmptyState();

    bool m_initialized = false;
    bool m_needsReinit = false;
    bool m_glFailed = false;
    bool m_isDark = true;
    
    // Renderer components
    std::unique_ptr<DiffRenderer> m_diffRenderer;
    std::unique_ptr<FontAtlas> m_fontAtlas; // Duplicate atlas for rendering
    
    // Viewport state
    float m_scrollOffset = 0.0f;
    int m_viewportWidth = 100;
    int m_viewportHeight = 100;
    float m_devicePixelRatio = 1.0f;

    // OpenGL resources
    std::unique_ptr<QOpenGLShaderProgram> m_rectShader;
    std::unique_ptr<QOpenGLShaderProgram> m_textShader;

    QOpenGLVertexArrayObject m_rectVao;
    QOpenGLVertexArrayObject m_textVao;
    
    QOpenGLBuffer m_quadBuffer{QOpenGLBuffer::VertexBuffer};
    QOpenGLBuffer m_rectInstanceBuffer{QOpenGLBuffer::VertexBuffer};
    QOpenGLBuffer m_textInstanceBuffer{QOpenGLBuffer::VertexBuffer};
    
    // Pending diffs to apply after OpenGL initialization
    std::vector<DiffSection> m_pendingDiffs;

    // Text selection state
    bool m_isSelecting = false;
    TextPosition m_selectionStart;

    // Persistent render result buffer (reused each frame to avoid reallocation)
    RenderResult m_renderResult;
    
    // Loading state
    bool m_isLoading = false;
    QTimer* m_loadingTimer = nullptr;
    QTimer* m_syntaxTimer = nullptr;
    QElapsedTimer m_loadingElapsed;
    
    // Bubble animation state
    struct Bubble {
        float x, y;       // Position (normalized 0-1)
        float size;       // Radius
        float speed;      // Rise speed
        float wobblePhase;// Phase for horizontal wobble
        float wobbleAmp;  // Amplitude of wobble
    };
    std::vector<Bubble> m_bubbles;

    // Fish animation state (simple boids-like swimming)
    struct Fish {
        float x, y;         // Position in pixels
        float vx, vy;       // Velocity
        float size;          // Body length
        float phase;         // Sine phase for tail wiggle
        float swimSpeed;     // Base swim speed
    };
    std::vector<Fish> m_fish;

    void initBubbles();
    void updateBubbles(float deltaTime);
    void initFish();
    void updateFish(float deltaTime);
    void renderUnderwaterScene();
    void startUnderwaterAnimation();
    void stopUnderwaterAnimation();
    void updateScrollBar();

    QScrollBar* m_scrollBar = nullptr;
};

} // namespace jules
