/**
 * OpenGL Text Rendering Widget
 * 
 * QOpenGLWidget subclass for GPU-accelerated text rendering.
 * Port of Mac's FluxRenderer.swift / MetalDiffView.swift.
 * 
 * Uses instanced quad rendering for efficient text display.
 */

#pragma once

#include <QOpenGLWidget>
#include <QOpenGLFunctions_3_3_Core>
#include <QOpenGLShaderProgram>
#include <QOpenGLBuffer>
#include <QOpenGLVertexArrayObject>

#include <memory>
#include <vector>
#include <string>

namespace jules {

// Forward declarations
class FontAtlas;

/**
 * Per-glyph instance data for GPU rendering.
 * Matches the layout expected by the vertex shader.
 */
struct InstanceData {
    float originX;
    float originY;
    float sizeX;
    float sizeY;
    float uvMinX;
    float uvMinY;
    float uvMaxX;
    float uvMaxY;
    float colorR;
    float colorG;
    float colorB;
    float colorA;
};

/**
 * Per-rectangle instance data for background rendering.
 */
struct RectInstance {
    float originX;
    float originY;
    float sizeX;
    float sizeY;
    float colorR;
    float colorG;
    float colorB;
    float colorA;
    float cornerRadius;
    float borderWidth;
    float borderColorR;
    float borderColorG;
    float borderColorB;
    float borderColorA;
    float padding1;  // Padding for 16-byte alignment
    float padding2;
};

/**
 * OpenGL widget for high-performance text rendering.
 * 
 * Uses instanced rendering with a single quad to draw thousands of glyphs
 * in a single draw call.
 * 
 * Usage:
 *   OpenGLTextWidget widget;
 *   widget.setText("Hello World");
 *   widget.show();
 */
class OpenGLTextWidget : public QOpenGLWidget, protected QOpenGLFunctions_3_3_Core {
    Q_OBJECT

public:
    explicit OpenGLTextWidget(QWidget* parent = nullptr);
    ~OpenGLTextWidget() override;
    
    /**
     * Set text to render.
     * Text will be rendered starting from top-left.
     */
    void setText(const std::string& text);
    
    /**
     * Set scroll position (camera offset).
     */
    void setScroll(float x, float y);
    
    /**
     * Get current frames per second.
     */
    float fps() const { return m_fps; }
    
    /**
     * Enable/disable FPS counter display.
     */
    void setShowFps(bool show);
    
signals:
    /**
     * Emitted after each frame with frame time in milliseconds.
     */
    void frameRendered(float frameTimeMs);

protected:
    // QOpenGLWidget overrides
    void initializeGL() override;
    void resizeGL(int w, int h) override;
    void paintGL() override;
    
private:
    void buildTextInstances();
    bool loadShaders();
    void setupBuffers();
    void updateInstanceBuffer();
    
    // Shaders
    std::unique_ptr<QOpenGLShaderProgram> m_textProgram;
    std::unique_ptr<QOpenGLShaderProgram> m_rectProgram;
    
    // Font atlas
    std::unique_ptr<FontAtlas> m_fontAtlas;
    
    // VAO and VBOs
    QOpenGLVertexArrayObject m_textVao;
    QOpenGLVertexArrayObject m_rectVao;
    QOpenGLBuffer m_quadBuffer{QOpenGLBuffer::VertexBuffer};
    QOpenGLBuffer m_textInstanceBuffer{QOpenGLBuffer::VertexBuffer};
    QOpenGLBuffer m_rectInstanceBuffer{QOpenGLBuffer::VertexBuffer};
    
    // Instance data
    std::vector<InstanceData> m_textInstances;
    std::vector<RectInstance> m_rectInstances;
    
    // Text content
    std::string m_text;
    
    // Camera/scroll state
    float m_cameraX = 0.0f;
    float m_cameraY = 0.0f;
    
    // Viewport state
    int m_viewportWidth = 100;
    int m_viewportHeight = 100;
    float m_devicePixelRatio = 1.0f;
    
    // FPS tracking
    float m_fps = 0.0f;
    qint64 m_lastFrameTime = 0;
    int m_frameCount = 0;
    qint64 m_fpsUpdateTime = 0;
    bool m_showFps = true;
    
    // Initialization state
    bool m_initialized = false;
};

} // namespace jules
