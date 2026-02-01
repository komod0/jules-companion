#include "rendering/wave_widget.h"

#include <QFile>
#include <QDebug>
#include <QOpenGLContext>
#include <QTimer>

#include <cmath>

namespace jules {

namespace {

static constexpr float kTopWaveVertices[] = {
    0.0f, 0.0f, 1.0f,
    1.0f, 0.0f, 1.0f,
    0.0f, 1.0f, 0.0f,
    1.0f, 0.0f, 1.0f,
    1.0f, 1.0f, 0.0f,
    0.0f, 1.0f, 0.0f,
};

static constexpr float kBottomWaveVertices[] = {
    0.0f, 0.0f, 0.0f,
    1.0f, 0.0f, 0.0f,
    0.0f, 1.0f, 1.0f,
    1.0f, 0.0f, 0.0f,
    1.0f, 1.0f, 1.0f,
    0.0f, 1.0f, 1.0f,
};

struct WaveUniformData {
    float viewSize[2];
    float time;
    float gravity;
    float fillColor[4];
    float strokeColor[4];
    float strokeWidth;
    float cornerRadius;
    int waveCount;
    int waveEdge;
};

void configureDefaultPreset(std::array<WaveParams, 8>& waves, int& count) {
    count = 3;
    waves[0] = { 8.0f, 60.0f, 0.3f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f };
    waves[1] = { 4.0f, 20.0f, 0.4f, 1.5f, 0.2f, 0.5f, 0.0f, 0.0f };
    waves[2] = { 2.0f, 8.0f, 0.5f, 2.0f, 0.1f, 1.0f, 0.0f, 0.0f };
}

void configureCalmPreset(std::array<WaveParams, 8>& waves, int& count) {
    count = 2;
    waves[0] = { 5.0f, 80.0f, 0.2f, 0.5f, 0.0f, 0.0f, 0.0f, 0.0f };
    waves[1] = { 3.0f, 30.0f, 0.3f, 0.7f, 0.3f, 0.5f, 0.0f, 0.0f };
}

void configureDramaticPreset(std::array<WaveParams, 8>& waves, int& count) {
    count = 4;
    waves[0] = { 10.0f, 40.0f, 0.5f, 1.2f, 0.0f, 0.0f, 0.0f, 0.0f };
    waves[1] = { 6.0f, 15.0f, 0.6f, 1.8f, 0.4f, 0.3f, 0.0f, 0.0f };
    waves[2] = { 4.0f, 8.0f, 0.7f, 2.2f, 0.2f, 0.7f, 0.0f, 0.0f };
    waves[3] = { 2.0f, 4.0f, 0.8f, 2.5f, 0.1f, 1.0f, 0.0f, 0.0f };
}

void configureSubtlePreset(std::array<WaveParams, 8>& waves, int& count) {
    count = 2;
    waves[0] = { 2.0f, 100.0f, 0.15f, 0.4f, 0.0f, 0.0f, 0.0f, 0.0f };
    waves[1] = { 1.0f, 40.0f, 0.2f, 0.6f, 0.2f, 0.3f, 0.0f, 0.0f };
}

void configureFlashMessagePreset(std::array<WaveParams, 8>& waves, int& count) {
    count = 2;
    waves[0] = { 6.0f, 50.0f, 0.25f, 0.8f, 0.0f, 0.0f, 0.0f, 0.0f };
    waves[1] = { 3.0f, 20.0f, 0.3f, 1.2f, 0.15f, 0.4f, 0.0f, 0.0f };
}

QString loadShaderSource(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qWarning() << "Failed to load shader:" << path;
        return {};
    }
    return QString::fromUtf8(file.readAll());
}

}

WaveWidget::WaveWidget(QWidget* parent)
    : QOpenGLWidget(parent)
{
    QSurfaceFormat format;
    format.setVersion(3, 3);
    format.setProfile(QSurfaceFormat::CoreProfile);
    format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
    format.setSwapInterval(1);
    setFormat(format);
    
    updateWavePresets();
}

WaveWidget::~WaveWidget() {
    if (m_initialized) {
        makeCurrent();
        m_vao.destroy();
        m_vertexBuffer.destroy();
        if (m_uniformBuffer) {
            glDeleteBuffers(1, &m_uniformBuffer);
        }
        m_program.reset();
        doneCurrent();
    }
}

bool WaveWidget::initialize() {
    if (m_initialized) return true;
    
    auto ctx = QOpenGLContext::currentContext();
    if (!ctx) {
        qWarning() << "No OpenGL context available";
        return false;
    }
    
    if (!initializeOpenGLFunctions()) {
        qWarning() << "Failed to initialize OpenGL 3.3 functions";
        return false;
    }
    
    if (!loadShaders()) {
        return false;
    }
    
    setupBuffers();
    m_initialized = true;
    return true;
}

bool WaveWidget::isInitialized() const { return m_initialized; }
bool WaveWidget::shadersValid() const { return m_shadersValid; }

void WaveWidget::setViewportSize(int width, int height, float devicePixelRatio) {
    m_viewportWidth = width;
    m_viewportHeight = height;
    m_devicePixelRatio = devicePixelRatio;
}

int WaveWidget::viewportWidth() const { return m_viewportWidth; }
int WaveWidget::viewportHeight() const { return m_viewportHeight; }
float WaveWidget::devicePixelRatio() const { return m_devicePixelRatio; }

void WaveWidget::setPreset(WavePreset preset) {
    m_preset = preset;
    updateWavePresets();
}

WavePreset WaveWidget::preset() const { return m_preset; }

void WaveWidget::setWaveEdge(WaveEdge edge) {
    if (m_waveEdge != edge) {
        m_waveEdge = edge;
        if (m_initialized) {
            setupBuffers();
        }
    }
}

WaveEdge WaveWidget::waveEdge() const { return m_waveEdge; }

void WaveWidget::setFillColor(const QColor& color) { m_fillColor = color; }
QColor WaveWidget::fillColor() const { return m_fillColor; }

void WaveWidget::setStrokeColor(const QColor& color) { m_strokeColor = color; }
QColor WaveWidget::strokeColor() const { return m_strokeColor; }

void WaveWidget::setStrokeWidth(float width) { m_strokeWidth = width; }
float WaveWidget::strokeWidth() const { return m_strokeWidth; }

void WaveWidget::setAutoplay(bool autoplay) {
    m_autoplay = autoplay;
    m_paused = !autoplay;
}

bool WaveWidget::isPaused() const { return m_paused; }
void WaveWidget::pause() { m_paused = true; }
void WaveWidget::resume() { m_paused = false; }
void WaveWidget::reset() { m_time = 0.0f; }
float WaveWidget::currentTime() const { return m_time; }

void WaveWidget::setWaveCount(int count) {
    m_waveCount = std::max(1, std::min(count, kMaxWaves));
}

int WaveWidget::waveCount() const { return m_waveCount; }

void WaveWidget::setWaveParams(int index, const WaveParams& params) {
    if (index >= 0 && index < kMaxWaves) {
        m_waveParams[index] = params;
    }
}

WaveParams WaveWidget::waveParams(int index) const {
    if (index >= 0 && index < kMaxWaves) {
        return m_waveParams[index];
    }
    return {};
}

void WaveWidget::initializeGL() {
    initialize();
    
    QTimer* timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, [this]() {
        if (!m_paused) {
            m_time += 0.016f;
            update();
        }
    });
    timer->start(16);
}

void WaveWidget::resizeGL(int w, int h) {
    m_viewportWidth = w;
    m_viewportHeight = h;
    glViewport(0, 0, static_cast<int>(w * m_devicePixelRatio),
               static_cast<int>(h * m_devicePixelRatio));
}

void WaveWidget::paintGL() {
    if (!m_initialized || !m_shadersValid) return;
    
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    updateUniformBuffer();
    
    m_program->bind();
    m_vao.bind();
    
    for (int i = 0; i < m_waveCount; ++i) {
        QString uniformName = QString("u_waves[%1].amplitude").arg(i);
        m_program->setUniformValue(uniformName.toUtf8().constData(), m_waveParams[i].amplitude);
        uniformName = QString("u_waves[%1].wavelength").arg(i);
        m_program->setUniformValue(uniformName.toUtf8().constData(), m_waveParams[i].wavelength);
        uniformName = QString("u_waves[%1].steepness").arg(i);
        m_program->setUniformValue(uniformName.toUtf8().constData(), m_waveParams[i].steepness);
        uniformName = QString("u_waves[%1].speed").arg(i);
        m_program->setUniformValue(uniformName.toUtf8().constData(), m_waveParams[i].speed);
        uniformName = QString("u_waves[%1].direction").arg(i);
        m_program->setUniformValue(uniformName.toUtf8().constData(), m_waveParams[i].direction);
        uniformName = QString("u_waves[%1].phaseOffset").arg(i);
        m_program->setUniformValue(uniformName.toUtf8().constData(), m_waveParams[i].phaseOffset);
    }
    
    glDrawArrays(GL_TRIANGLES, 0, 6);
    
    m_vao.release();
    m_program->release();
    
    glDisable(GL_BLEND);
}

void WaveWidget::setupBuffers() {
    if (m_vao.isCreated()) {
        m_vao.destroy();
    }
    if (m_vertexBuffer.isCreated()) {
        m_vertexBuffer.destroy();
    }
    
    m_vao.create();
    m_vao.bind();
    
    m_vertexBuffer.create();
    m_vertexBuffer.bind();
    
    const float* vertices = (m_waveEdge == WaveEdge::Bottom) ? kBottomWaveVertices : kTopWaveVertices;
    m_vertexBuffer.allocate(vertices, 6 * 3 * sizeof(float));
    
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);
    
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 3 * sizeof(float), 
                          reinterpret_cast<void*>(2 * sizeof(float)));
    
    m_vertexBuffer.release();
    m_vao.release();
    
    if (!m_uniformBuffer) {
        glGenBuffers(1, &m_uniformBuffer);
    }
    glBindBuffer(GL_UNIFORM_BUFFER, m_uniformBuffer);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(WaveUniformData), nullptr, GL_DYNAMIC_DRAW);
    glBindBuffer(GL_UNIFORM_BUFFER, 0);
}

bool WaveWidget::loadShaders() {
    m_program = std::make_unique<QOpenGLShaderProgram>();
    
    QString vertSource = loadShaderSource(":/shaders/wave.vert");
    QString fragSource = loadShaderSource(":/shaders/wave.frag");
    
    if (vertSource.isEmpty()) {
        vertSource = loadShaderSource("shaders/wave.vert");
    }
    if (fragSource.isEmpty()) {
        fragSource = loadShaderSource("shaders/wave.frag");
    }
    
    if (vertSource.isEmpty() || fragSource.isEmpty()) {
        qWarning() << "Failed to load wave shaders";
        return false;
    }
    
    if (!m_program->addShaderFromSourceCode(QOpenGLShader::Vertex, vertSource)) {
        qWarning() << "Wave vertex shader compile error:" << m_program->log();
        return false;
    }
    
    if (!m_program->addShaderFromSourceCode(QOpenGLShader::Fragment, fragSource)) {
        qWarning() << "Wave fragment shader compile error:" << m_program->log();
        return false;
    }
    
    if (!m_program->link()) {
        qWarning() << "Wave shader link error:" << m_program->log();
        return false;
    }
    
    m_shadersValid = true;
    return true;
}

void WaveWidget::updateUniformBuffer() {
    if (!m_program) return;
    
    m_program->setUniformValue("u_viewSize", QVector2D(m_viewportWidth, m_viewportHeight));
    m_program->setUniformValue("u_time", m_time);
    m_program->setUniformValue("u_gravity", kGravity);
    m_program->setUniformValue("u_fillColor", QVector4D(
        m_fillColor.redF(), m_fillColor.greenF(), m_fillColor.blueF(), m_fillColor.alphaF()));
    m_program->setUniformValue("u_strokeColor", QVector4D(
        m_strokeColor.redF(), m_strokeColor.greenF(), m_strokeColor.blueF(), m_strokeColor.alphaF()));
    m_program->setUniformValue("u_strokeWidth", m_strokeWidth);
    m_program->setUniformValue("u_waveCount", m_waveCount);
    m_program->setUniformValue("u_waveEdge", static_cast<int>(m_waveEdge));
}

void WaveWidget::updateWavePresets() {
    switch (m_preset) {
        case WavePreset::Default:
            configureDefaultPreset(m_waveParams, m_waveCount);
            break;
        case WavePreset::Calm:
            configureCalmPreset(m_waveParams, m_waveCount);
            break;
        case WavePreset::Dramatic:
            configureDramaticPreset(m_waveParams, m_waveCount);
            break;
        case WavePreset::Subtle:
            configureSubtlePreset(m_waveParams, m_waveCount);
            break;
        case WavePreset::FlashMessage:
            configureFlashMessagePreset(m_waveParams, m_waveCount);
            m_waveEdge = WaveEdge::Bottom;
            break;
    }
}

}
