/**
 * OpenGL Text Rendering Widget Implementation
 * 
 * Port of Mac's FluxRenderer.swift.
 */

#include "rendering/opengl_widget.h"
#include "rendering/font_atlas.h"

#include <QFile>
#include <QDateTime>
#include <QDebug>

#include <cmath>

namespace jules {

// =============================================================================
// Shader source loading
// =============================================================================

static QString loadShaderSource(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qWarning() << "Failed to load shader:" << path;
        return {};
    }
    return QString::fromUtf8(file.readAll());
}

// Unit quad vertices (two triangles)
static constexpr float quadVertices[] = {
    0.0f, 0.0f,  // Bottom-left
    1.0f, 0.0f,  // Bottom-right
    0.0f, 1.0f,  // Top-left
    
    1.0f, 0.0f,  // Bottom-right
    1.0f, 1.0f,  // Top-right
    0.0f, 1.0f,  // Top-left
};

// =============================================================================
// OpenGLTextWidget Implementation
// =============================================================================

OpenGLTextWidget::OpenGLTextWidget(QWidget* parent)
    : QOpenGLWidget(parent)
{
    // Request OpenGL 3.3 Core
    QSurfaceFormat format;
    format.setVersion(3, 3);
    format.setProfile(QSurfaceFormat::CoreProfile);
    format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
    format.setSwapInterval(1);  // VSync
    setFormat(format);
}

OpenGLTextWidget::~OpenGLTextWidget() {
    makeCurrent();
    
    // Cleanup OpenGL resources
    m_textVao.destroy();
    m_rectVao.destroy();
    m_quadBuffer.destroy();
    m_textInstanceBuffer.destroy();
    m_rectInstanceBuffer.destroy();
    
    m_textProgram.reset();
    m_rectProgram.reset();
    m_fontAtlas.reset();
    
    doneCurrent();
}

void OpenGLTextWidget::setText(const std::string& text) {
    m_text = text;
    if (m_initialized) {
        buildTextInstances();
        update();
    }
}

void OpenGLTextWidget::setScroll(float x, float y) {
    m_cameraX = x;
    m_cameraY = y;
    update();
}

void OpenGLTextWidget::setShowFps(bool show) {
    m_showFps = show;
}

void OpenGLTextWidget::initializeGL() {
    if (!initializeOpenGLFunctions()) {
        qCritical() << "Failed to initialize OpenGL functions";
        return;
    }
    
    qDebug() << "OpenGL version:" << reinterpret_cast<const char*>(glGetString(GL_VERSION));
    qDebug() << "GLSL version:" << reinterpret_cast<const char*>(glGetString(GL_SHADING_LANGUAGE_VERSION));
    
    // Enable blending for alpha
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    // Disable depth test (2D rendering)
    glDisable(GL_DEPTH_TEST);
    
    // Load shaders
    if (!loadShaders()) {
        qCritical() << "Failed to load shaders";
        return;
    }
    
    // Initialize font atlas
    m_devicePixelRatio = devicePixelRatioF();
    m_fontAtlas = std::make_unique<FontAtlas>();
    if (!m_fontAtlas->initialize(12.0f, m_devicePixelRatio)) {
        qCritical() << "Failed to initialize font atlas";
        return;
    }
    
    // Setup buffers
    setupBuffers();
    
    m_initialized = true;
    
    // Build initial text if set
    if (!m_text.empty()) {
        buildTextInstances();
    }
    
    m_fpsUpdateTime = QDateTime::currentMSecsSinceEpoch();
}

void OpenGLTextWidget::resizeGL(int w, int h) {
    m_viewportWidth = w;
    m_viewportHeight = h;
    
    // Update device pixel ratio
    float newRatio = devicePixelRatioF();
    if (std::abs(newRatio - m_devicePixelRatio) > 0.1f) {
        m_devicePixelRatio = newRatio;
        if (m_fontAtlas) {
            m_fontAtlas->updateScale(m_devicePixelRatio);
        }
    }
    
    glViewport(0, 0, w * m_devicePixelRatio, h * m_devicePixelRatio);
}

void OpenGLTextWidget::paintGL() {
    if (!m_initialized) return;
    
    qint64 frameStart = QDateTime::currentMSecsSinceEpoch();
    
    // Clear background
    glClearColor(0.1f, 0.1f, 0.1f, 1.0f);  // Dark background
    glClear(GL_COLOR_BUFFER_BIT);
    
    // Viewport size in logical points
    float viewportPointsW = static_cast<float>(m_viewportWidth);
    float viewportPointsH = static_cast<float>(m_viewportHeight);
    
    // Draw background rectangles (if any)
    if (!m_rectInstances.empty() && m_rectProgram) {
        m_rectProgram->bind();
        m_rectProgram->setUniformValue("u_viewportSize", viewportPointsW, viewportPointsH);
        m_rectProgram->setUniformValue("u_camera", m_cameraX, m_cameraY);
        m_rectProgram->setUniformValue("u_scale", m_devicePixelRatio);
        
        m_rectVao.bind();
        glDrawArraysInstanced(GL_TRIANGLES, 0, 6, static_cast<GLsizei>(m_rectInstances.size()));
        m_rectVao.release();
        m_rectProgram->release();
    }
    
    // Draw text instances
    if (!m_textInstances.empty() && m_textProgram && m_fontAtlas) {
        m_textProgram->bind();
        m_textProgram->setUniformValue("u_viewportSize", viewportPointsW, viewportPointsH);
        m_textProgram->setUniformValue("u_camera", m_cameraX, m_cameraY);
        
        // Bind font atlas texture
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, m_fontAtlas->textureId());
        m_textProgram->setUniformValue("u_atlas", 0);
        
        m_textVao.bind();
        glDrawArraysInstanced(GL_TRIANGLES, 0, 6, static_cast<GLsizei>(m_textInstances.size()));
        m_textVao.release();
        m_textProgram->release();
    }
    
    // FPS calculation
    qint64 frameEnd = QDateTime::currentMSecsSinceEpoch();
    float frameTimeMs = static_cast<float>(frameEnd - frameStart);
    emit frameRendered(frameTimeMs);
    
    m_frameCount++;
    if (frameEnd - m_fpsUpdateTime >= 1000) {
        m_fps = static_cast<float>(m_frameCount) * 1000.0f / static_cast<float>(frameEnd - m_fpsUpdateTime);
        m_frameCount = 0;
        m_fpsUpdateTime = frameEnd;
        
        if (m_showFps) {
            qDebug() << "FPS:" << m_fps << "Instances:" << m_textInstances.size();
        }
    }
    
    m_lastFrameTime = frameEnd;
}

bool OpenGLTextWidget::loadShaders() {
    // Load text shaders
    m_textProgram = std::make_unique<QOpenGLShaderProgram>();
    
    QString vertSource = loadShaderSource(":/shaders/text.vert");
    QString fragSource = loadShaderSource(":/shaders/text.frag");
    
    // If loading from Qt resources fails, try filesystem paths
    if (vertSource.isEmpty()) {
        vertSource = loadShaderSource("shaders/text.vert");
    }
    if (fragSource.isEmpty()) {
        fragSource = loadShaderSource("shaders/text.frag");
    }
    
    if (vertSource.isEmpty() || fragSource.isEmpty()) {
        qCritical() << "Failed to load text shader sources";
        return false;
    }
    
    if (!m_textProgram->addShaderFromSourceCode(QOpenGLShader::Vertex, vertSource)) {
        qCritical() << "Vertex shader compilation failed:" << m_textProgram->log();
        return false;
    }
    
    if (!m_textProgram->addShaderFromSourceCode(QOpenGLShader::Fragment, fragSource)) {
        qCritical() << "Fragment shader compilation failed:" << m_textProgram->log();
        return false;
    }
    
    if (!m_textProgram->link()) {
        qCritical() << "Shader program linking failed:" << m_textProgram->log();
        return false;
    }
    
    // Load rect shaders (optional - for backgrounds)
    m_rectProgram = std::make_unique<QOpenGLShaderProgram>();
    
    QString rectVertSource = loadShaderSource(":/shaders/rect.vert");
    QString rectFragSource = loadShaderSource(":/shaders/rect.frag");
    
    if (rectVertSource.isEmpty()) {
        rectVertSource = loadShaderSource("shaders/rect.vert");
    }
    if (rectFragSource.isEmpty()) {
        rectFragSource = loadShaderSource("shaders/rect.frag");
    }
    
    if (!rectVertSource.isEmpty() && !rectFragSource.isEmpty()) {
        m_rectProgram->addShaderFromSourceCode(QOpenGLShader::Vertex, rectVertSource);
        m_rectProgram->addShaderFromSourceCode(QOpenGLShader::Fragment, rectFragSource);
        m_rectProgram->link();
    }
    
    return true;
}

void OpenGLTextWidget::setupBuffers() {
    // Create and populate quad buffer
    m_quadBuffer.create();
    m_quadBuffer.bind();
    m_quadBuffer.allocate(quadVertices, sizeof(quadVertices));
    m_quadBuffer.release();
    
    // Create text instance buffer
    m_textInstanceBuffer.create();
    m_textInstanceBuffer.setUsagePattern(QOpenGLBuffer::DynamicDraw);
    
    // Create rect instance buffer
    m_rectInstanceBuffer.create();
    m_rectInstanceBuffer.setUsagePattern(QOpenGLBuffer::DynamicDraw);
    
    // Setup text VAO
    m_textVao.create();
    m_textVao.bind();
    
    // Quad vertices (location 0)
    m_quadBuffer.bind();
    m_textProgram->enableAttributeArray(0);
    m_textProgram->setAttributeBuffer(0, GL_FLOAT, 0, 2, 2 * sizeof(float));
    
    // Instance attributes (locations 1-5)
    m_textInstanceBuffer.bind();
    
    // i_origin (location 1)
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(InstanceData), 
                          reinterpret_cast<void*>(offsetof(InstanceData, originX)));
    glVertexAttribDivisor(1, 1);
    
    // i_size (location 2)
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, sizeof(InstanceData),
                          reinterpret_cast<void*>(offsetof(InstanceData, sizeX)));
    glVertexAttribDivisor(2, 1);
    
    // i_uvMin (location 3)
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, sizeof(InstanceData),
                          reinterpret_cast<void*>(offsetof(InstanceData, uvMinX)));
    glVertexAttribDivisor(3, 1);
    
    // i_uvMax (location 4)
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 2, GL_FLOAT, GL_FALSE, sizeof(InstanceData),
                          reinterpret_cast<void*>(offsetof(InstanceData, uvMaxX)));
    glVertexAttribDivisor(4, 1);
    
    // i_color (location 5)
    glEnableVertexAttribArray(5);
    glVertexAttribPointer(5, 4, GL_FLOAT, GL_FALSE, sizeof(InstanceData),
                          reinterpret_cast<void*>(offsetof(InstanceData, colorR)));
    glVertexAttribDivisor(5, 1);
    
    m_textVao.release();
    
    // Setup rect VAO (similar structure)
    m_rectVao.create();
    m_rectVao.bind();
    
    m_quadBuffer.bind();
    if (m_rectProgram) {
        m_rectProgram->enableAttributeArray(0);
        m_rectProgram->setAttributeBuffer(0, GL_FLOAT, 0, 2, 2 * sizeof(float));
    }
    
    m_rectVao.release();
}

void OpenGLTextWidget::buildTextInstances() {
    if (!m_fontAtlas || !m_fontAtlas->isValid()) {
        return;
    }
    
    m_textInstances.clear();
    
    float x = 10.0f;  // Starting X position
    float y = 10.0f + m_fontAtlas->lineHeight();  // Starting Y (with ascender offset)
    float lineHeight = m_fontAtlas->lineHeight();
    float monoAdvance = m_fontAtlas->monoAdvance();
    
    // Text color (light gray on dark background)
    float colorR = 0.9f;
    float colorG = 0.9f;
    float colorB = 0.9f;
    float colorA = 1.0f;
    
    for (char c : m_text) {
        if (c == '\n') {
            x = 10.0f;
            y += lineHeight;
            continue;
        }
        
        if (c == '\r') {
            continue;
        }
        
        // Skip whitespace (don't render, but advance)
        if (c == ' ' || c == '\t') {
            x += (c == '\t') ? monoAdvance * 4.0f : monoAdvance;
            continue;
        }
        
        // Get glyph from atlas
        const GlyphDescriptor* glyph = m_fontAtlas->getASCIIGlyph(c);
        if (!glyph) {
            // Use '?' for unknown characters
            glyph = m_fontAtlas->getASCIIGlyph('?');
            if (!glyph) {
                x += monoAdvance;
                continue;
            }
        }
        
        // Create instance
        InstanceData instance;
        instance.originX = x;
        instance.originY = y - glyph->bearing.y;  // Baseline alignment
        instance.sizeX = glyph->size.x;
        instance.sizeY = glyph->size.y;
        instance.uvMinX = glyph->uvMin.x;
        instance.uvMinY = glyph->uvMin.y;
        instance.uvMaxX = glyph->uvMax.x;
        instance.uvMaxY = glyph->uvMax.y;
        instance.colorR = colorR;
        instance.colorG = colorG;
        instance.colorB = colorB;
        instance.colorA = colorA;
        
        m_textInstances.push_back(instance);
        
        x += glyph->advance;
    }
    
    // Update GPU buffer
    updateInstanceBuffer();
}

void OpenGLTextWidget::updateInstanceBuffer() {
    if (m_textInstances.empty()) {
        return;
    }
    
    makeCurrent();
    
    m_textInstanceBuffer.bind();
    
    size_t size = m_textInstances.size() * sizeof(InstanceData);
    m_textInstanceBuffer.allocate(m_textInstances.data(), static_cast<int>(size));
    
    m_textInstanceBuffer.release();
    
    doneCurrent();
}

} // namespace jules
