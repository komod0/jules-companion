#pragma once

#include <QOpenGLWidget>
#include <QOpenGLFunctions_3_3_Core>
#include <QOpenGLShaderProgram>
#include <QOpenGLBuffer>
#include <QOpenGLVertexArrayObject>
#include <QColor>

#include <array>
#include <memory>

namespace jules {

// Wave parameters per component
struct WaveParams {
    float amplitude = 1.0f;     // Wave height
    float wavelength = 10.0f;   // Distance between crests
    float steepness = 0.5f;     // Q factor (0-1, controls sharpness)
    float speed = 1.0f;         // Speed multiplier
    float direction = 0.0f;     // Direction in radians
    float phaseOffset = 0.0f;   // Initial phase
    float padding1 = 0.0f;
    float padding2 = 0.0f;
};

// Preset wave configurations
enum class WavePreset {
    Default,      // Ocean swell + chop + ripple
    Calm,         // Gentle, slow waves
    Dramatic,     // Choppy, high-amplitude
    Subtle,       // Minimal UI background
    FlashMessage  // Bottom-edge for notifications
};

// Wave edge position
enum class WaveEdge {
    Top,
    Bottom
};

class WaveWidget : public QOpenGLWidget, protected QOpenGLFunctions_3_3_Core {
    Q_OBJECT

public:
    explicit WaveWidget(QWidget* parent = nullptr);
    ~WaveWidget() override;
    
    WaveWidget(const WaveWidget&) = delete;
    WaveWidget& operator=(const WaveWidget&) = delete;
    
    bool initialize();
    bool isInitialized() const;
    bool shadersValid() const;
    
    // Viewport
    void setViewportSize(int width, int height, float devicePixelRatio);
    int viewportWidth() const;
    int viewportHeight() const;
    float devicePixelRatio() const;
    
    // Wave configuration
    void setPreset(WavePreset preset);
    WavePreset preset() const;
    
    void setWaveEdge(WaveEdge edge);
    WaveEdge waveEdge() const;
    
    void setFillColor(const QColor& color);
    QColor fillColor() const;
    
    void setStrokeColor(const QColor& color);
    QColor strokeColor() const;
    
    void setStrokeWidth(float width);
    float strokeWidth() const;
    
    // Animation
    void setAutoplay(bool autoplay);
    bool isPaused() const;
    void pause();
    void resume();
    void reset();
    
    float currentTime() const;
    
    // Custom wave configuration
    void setWaveCount(int count);
    int waveCount() const;
    
    void setWaveParams(int index, const WaveParams& params);
    WaveParams waveParams(int index) const;

protected:
    void initializeGL() override;
    void resizeGL(int w, int h) override;
    void paintGL() override;

private:
    void setupBuffers();
    bool loadShaders();
    void updateUniformBuffer();
    void updateWavePresets();
    
    bool m_initialized = false;
    bool m_shadersValid = false;
    bool m_paused = false;
    bool m_autoplay = true;
    
    int m_viewportWidth = 800;
    int m_viewportHeight = 600;
    float m_devicePixelRatio = 1.0f;
    
    WavePreset m_preset = WavePreset::Default;
    WaveEdge m_waveEdge = WaveEdge::Bottom;
    
    QColor m_fillColor{100, 150, 255, 255};
    QColor m_strokeColor{80, 130, 255, 255};
    float m_strokeWidth = 0.0f;
    float m_cornerRadius = 0.0f;
    
    static constexpr int kMaxWaves = 8;
    int m_waveCount = 3;
    std::array<WaveParams, kMaxWaves> m_waveParams;
    
    float m_time = 0.0f;
    static constexpr float kGravity = 9.81f;
    
    // OpenGL resources
    std::unique_ptr<QOpenGLShaderProgram> m_program;
    QOpenGLVertexArrayObject m_vao;
    QOpenGLBuffer m_vertexBuffer{QOpenGLBuffer::VertexBuffer};
    GLuint m_uniformBuffer = 0;
};

} // namespace jules
