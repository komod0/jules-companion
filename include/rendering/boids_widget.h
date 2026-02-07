#pragma once

#include "rendering/diff_renderer.h"

#include <QOpenGLWidget>
#include <QOpenGLFunctions_4_3_Core>
#include <QOpenGLShaderProgram>
#include <QOpenGLBuffer>
#include <QOpenGLVertexArrayObject>

#include <memory>
#include <vector>

namespace jules {

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

struct BoidParticle {
    Vec2 position;
    Vec2 velocity;
};

enum class BoidsRenderMode {
    Full,
    Minimal
};

class BoidsWidget : public QOpenGLWidget, protected QOpenGLFunctions_4_3_Core {
    Q_OBJECT

public:
    explicit BoidsWidget(QWidget* parent = nullptr);
    ~BoidsWidget() override;
    
    BoidsWidget(const BoidsWidget&) = delete;
    BoidsWidget& operator=(const BoidsWidget&) = delete;
    
    bool initialize();
    bool isInitialized() const;

    // Adaptive memory management
    void releaseResources();
    
    bool hasComputeShaderSupport() const;
    bool computeShaderValid() const;
    bool renderShadersValid() const;
    
    void setViewportSize(int width, int height, float devicePixelRatio);
    int viewportWidth() const;
    int viewportHeight() const;
    float devicePixelRatio() const;
    
    void setParticleCount(int count);
    int particleCount() const;
    
    std::vector<BoidParticle> particles() const;
    
    void setParticleColor(const RGBA& color);
    RGBA particleColor() const;
    
    void setBackgroundColor(const RGBA& color);
    RGBA backgroundColor() const;
    
    void setRenderMode(BoidsRenderMode mode);
    BoidsRenderMode renderMode() const;
    
    void setAutoplay(bool autoplay);
    bool isPaused() const;
    void pause();
    void resume();
    void reset();
    
    void update(float deltaTime);
    void render();
    
    static constexpr int kDefaultParticleCount = 1000;
    static constexpr int kMinParticleCount = 10;
    static constexpr int kMaxParticleCount = 10000;

protected:
    void initializeGL() override;
    void resizeGL(int w, int h) override;
    void paintGL() override;

private:
    void initializeParticles();
    bool loadShaders();
    void setupBuffers();
    void runComputeShader(float deltaTime);
    void updateUniformBuffer();
    
    bool m_initialized = false;
    bool m_needsReinit = false;
    bool m_hasComputeShader = false;
    bool m_computeShaderValid = false;
    bool m_renderShadersValid = false;
    bool m_paused = false;
    bool m_autoplay = true;
    
    int m_viewportWidth = 800;
    int m_viewportHeight = 600;
    float m_devicePixelRatio = 1.0f;
    
    int m_particleCount = kDefaultParticleCount;
    
    RGBA m_particleColor{0.541f, 0.459f, 1.0f, 1.0f};
    RGBA m_backgroundColor{0.1f, 0.1f, 0.1f, 1.0f};
    
    BoidsRenderMode m_renderMode = BoidsRenderMode::Full;
    
    float m_time = 0.0f;
    
    std::unique_ptr<QOpenGLShaderProgram> m_computeProgram;
    std::unique_ptr<QOpenGLShaderProgram> m_renderProgram;
    
    QOpenGLVertexArrayObject m_vao;
    QOpenGLBuffer m_quadBuffer{QOpenGLBuffer::VertexBuffer};
    
    GLuint m_particleSSBO = 0;
    GLuint m_uniformUBO = 0;
    
    std::vector<BoidParticle> m_particles;
};

} // namespace jules
