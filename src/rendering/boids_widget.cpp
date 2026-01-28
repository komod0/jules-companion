#include "rendering/boids_widget.h"

#include <QFile>
#include <QDebug>
#include <QDateTime>
#include <QOpenGLContext>

#include <cmath>
#include <random>

namespace jules {

namespace {

static constexpr float kQuadVertices[] = {
    0.0f, 0.0f,
    1.0f, 0.0f,
    0.0f, 1.0f,
    1.0f, 0.0f,
    1.0f, 1.0f,
    0.0f, 1.0f,
};

struct BoidsUniformData {
    float resolution[2];
    float time;
    float deltaTime;
    float fishColor[4];
    float backgroundColor[4];
    int numFish;
    int padding1;
    int padding2;
    int padding3;
};

QString loadShaderSource(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qWarning() << "Failed to load shader:" << path;
        return {};
    }
    return QString::fromUtf8(file.readAll());
}

} // namespace

BoidsWidget::BoidsWidget(QWidget* parent)
    : QOpenGLWidget(parent)
{
    QSurfaceFormat format;
    format.setVersion(4, 3);
    format.setProfile(QSurfaceFormat::CoreProfile);
    format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
    format.setSwapInterval(1);
    setFormat(format);
}

BoidsWidget::~BoidsWidget() {
    if (m_initialized) {
        makeCurrent();
        
        m_vao.destroy();
        m_quadBuffer.destroy();
        
        if (m_particleSSBO) {
            glDeleteBuffers(1, &m_particleSSBO);
        }
        if (m_uniformUBO) {
            glDeleteBuffers(1, &m_uniformUBO);
        }
        
        m_computeProgram.reset();
        m_renderProgram.reset();
        
        doneCurrent();
    }
}

bool BoidsWidget::initialize() {
    if (m_initialized) return true;
    
    auto ctx = QOpenGLContext::currentContext();
    if (!ctx) {
        qWarning() << "No OpenGL context available";
        return false;
    }
    
    if (!initializeOpenGLFunctions()) {
        qWarning() << "Failed to initialize OpenGL 4.3 functions";
        return false;
    }
    
    const char* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
    if (version) {
        int major = 0, minor = 0;
        sscanf(version, "%d.%d", &major, &minor);
        m_hasComputeShader = (major > 4) || (major == 4 && minor >= 3);
    }
    
    if (!m_hasComputeShader) {
        qWarning() << "OpenGL 4.3+ required for compute shaders";
        return false;
    }
    
    if (!loadShaders()) {
        return false;
    }
    
    setupBuffers();
    initializeParticles();
    
    m_initialized = true;
    return true;
}

bool BoidsWidget::isInitialized() const {
    return m_initialized;
}

bool BoidsWidget::hasComputeShaderSupport() const {
    return m_hasComputeShader;
}

bool BoidsWidget::computeShaderValid() const {
    return m_computeShaderValid;
}

bool BoidsWidget::renderShadersValid() const {
    return m_renderShadersValid;
}

void BoidsWidget::setViewportSize(int width, int height, float devicePixelRatio) {
    m_viewportWidth = width;
    m_viewportHeight = height;
    m_devicePixelRatio = devicePixelRatio;
}

int BoidsWidget::viewportWidth() const {
    return m_viewportWidth;
}

int BoidsWidget::viewportHeight() const {
    return m_viewportHeight;
}

float BoidsWidget::devicePixelRatio() const {
    return m_devicePixelRatio;
}

void BoidsWidget::setParticleCount(int count) {
    count = std::max(kMinParticleCount, std::min(count, kMaxParticleCount));
    
    if (count != m_particleCount) {
        m_particleCount = count;
        if (m_initialized) {
            initializeParticles();
        }
    }
}

int BoidsWidget::particleCount() const {
    return m_particleCount;
}

std::vector<BoidParticle> BoidsWidget::particles() const {
    return m_particles;
}

void BoidsWidget::setParticleColor(const RGBA& color) {
    m_particleColor = color;
}

RGBA BoidsWidget::particleColor() const {
    return m_particleColor;
}

void BoidsWidget::setBackgroundColor(const RGBA& color) {
    m_backgroundColor = color;
}

RGBA BoidsWidget::backgroundColor() const {
    return m_backgroundColor;
}

void BoidsWidget::setRenderMode(BoidsRenderMode mode) {
    m_renderMode = mode;
}

BoidsRenderMode BoidsWidget::renderMode() const {
    return m_renderMode;
}

void BoidsWidget::setAutoplay(bool autoplay) {
    m_autoplay = autoplay;
    m_paused = !autoplay;
}

bool BoidsWidget::isPaused() const {
    return m_paused;
}

void BoidsWidget::pause() {
    m_paused = true;
}

void BoidsWidget::resume() {
    m_paused = false;
}

void BoidsWidget::reset() {
    m_time = 0.0f;
    initializeParticles();
}

void BoidsWidget::update(float deltaTime) {
    if (m_paused || !m_initialized) return;
    
    m_time += deltaTime;
    runComputeShader(deltaTime);
}

void BoidsWidget::render() {
    if (!m_initialized) return;
    paintGL();
}

void BoidsWidget::initializeGL() {
    initialize();
}

void BoidsWidget::resizeGL(int w, int h) {
    m_viewportWidth = w;
    m_viewportHeight = h;
    glViewport(0, 0, static_cast<int>(w * m_devicePixelRatio), 
               static_cast<int>(h * m_devicePixelRatio));
}

void BoidsWidget::paintGL() {
    if (!m_initialized) return;
    
    glClearColor(m_backgroundColor.r, m_backgroundColor.g, 
                 m_backgroundColor.b, m_backgroundColor.a);
    glClear(GL_COLOR_BUFFER_BIT);
    
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    if (m_renderProgram && m_renderShadersValid) {
        updateUniformBuffer();
        
        m_renderProgram->bind();
        
        int renderModeVal = (m_renderMode == BoidsRenderMode::Full) ? 0 : 1;
        m_renderProgram->setUniformValue("u_renderMode", renderModeVal);
        
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, m_particleSSBO);
        glBindBufferBase(GL_UNIFORM_BUFFER, 1, m_uniformUBO);
        
        m_vao.bind();
        glDrawArrays(GL_TRIANGLES, 0, 6);
        m_vao.release();
        
        m_renderProgram->release();
    }
}

void BoidsWidget::initializeParticles() {
    m_particles.clear();
    m_particles.reserve(m_particleCount);
    
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> posDist(-1.0f, 1.0f);
    std::uniform_real_distribution<float> velDist(-0.01f, 0.01f);
    std::uniform_real_distribution<float> spawnChoice(0.0f, 1.0f);
    
    float aspect = static_cast<float>(m_viewportWidth) / static_cast<float>(m_viewportHeight);
    if (aspect < 0.1f) aspect = 16.0f / 9.0f;
    
    for (int i = 0; i < m_particleCount; ++i) {
        BoidParticle p;
        
        bool spawnFromSide = spawnChoice(gen) < 0.3f;
        
        if (spawnFromSide) {
            bool fromLeft = spawnChoice(gen) > 0.5f;
            p.position.x = fromLeft ? (-aspect - 0.5f) : (aspect + 0.5f);
            p.position.y = posDist(gen);
            p.velocity.x = fromLeft ? 0.003f : -0.003f;
            p.velocity.y = velDist(gen) + 0.002f;
        } else {
            p.position.x = posDist(gen) * aspect * 0.8f;
            p.position.y = -1.5f - static_cast<float>(i) * 0.1f - spawnChoice(gen) * 0.5f;
            p.velocity.x = velDist(gen);
            p.velocity.y = std::abs(velDist(gen)) + 0.002f;
        }
        
        m_particles.push_back(p);
    }
    
    if (m_particleSSBO) {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, m_particleSSBO);
        glBufferData(GL_SHADER_STORAGE_BUFFER, 
                     m_particles.size() * sizeof(BoidParticle),
                     m_particles.data(), GL_DYNAMIC_COPY);
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
    }
}

bool BoidsWidget::loadShaders() {
    QString computeSource = loadShaderSource(":/shaders/boids.comp");
    if (computeSource.isEmpty()) {
        computeSource = loadShaderSource("shaders/boids.comp");
    }
    
    QString vertSource = loadShaderSource(":/shaders/boids.vert");
    if (vertSource.isEmpty()) {
        vertSource = loadShaderSource("shaders/boids.vert");
    }
    
    QString fragSource = loadShaderSource(":/shaders/boids.frag");
    if (fragSource.isEmpty()) {
        fragSource = loadShaderSource("shaders/boids.frag");
    }
    
    m_computeProgram = std::make_unique<QOpenGLShaderProgram>();
    if (!computeSource.isEmpty()) {
        if (m_computeProgram->addShaderFromSourceCode(QOpenGLShader::Compute, computeSource)) {
            if (m_computeProgram->link()) {
                m_computeShaderValid = true;
            } else {
                qWarning() << "Compute shader link failed:" << m_computeProgram->log();
            }
        } else {
            qWarning() << "Compute shader compile failed:" << m_computeProgram->log();
        }
    }
    
    m_renderProgram = std::make_unique<QOpenGLShaderProgram>();
    if (!vertSource.isEmpty() && !fragSource.isEmpty()) {
        bool vertOk = m_renderProgram->addShaderFromSourceCode(QOpenGLShader::Vertex, vertSource);
        bool fragOk = m_renderProgram->addShaderFromSourceCode(QOpenGLShader::Fragment, fragSource);
        
        if (vertOk && fragOk) {
            if (m_renderProgram->link()) {
                m_renderShadersValid = true;
            } else {
                qWarning() << "Render shader link failed:" << m_renderProgram->log();
            }
        } else {
            qWarning() << "Render shader compile failed:" << m_renderProgram->log();
        }
    }
    
    return m_computeShaderValid && m_renderShadersValid;
}

void BoidsWidget::setupBuffers() {
    m_vao.create();
    m_vao.bind();
    
    m_quadBuffer.create();
    m_quadBuffer.bind();
    m_quadBuffer.allocate(kQuadVertices, sizeof(kQuadVertices));
    
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), nullptr);
    
    m_quadBuffer.release();
    m_vao.release();
    
    glGenBuffers(1, &m_particleSSBO);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, m_particleSSBO);
    glBufferData(GL_SHADER_STORAGE_BUFFER, 
                 m_particleCount * sizeof(BoidParticle),
                 nullptr, GL_DYNAMIC_COPY);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
    
    glGenBuffers(1, &m_uniformUBO);
    glBindBuffer(GL_UNIFORM_BUFFER, m_uniformUBO);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(BoidsUniformData), nullptr, GL_DYNAMIC_DRAW);
    glBindBuffer(GL_UNIFORM_BUFFER, 0);
}

void BoidsWidget::runComputeShader(float deltaTime) {
    if (!m_computeShaderValid || !m_computeProgram) return;
    
    updateUniformBuffer();
    
    m_computeProgram->bind();
    
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, m_particleSSBO);
    glBindBufferBase(GL_UNIFORM_BUFFER, 1, m_uniformUBO);
    
    int workGroupSize = 64;
    int numWorkGroups = (m_particleCount + workGroupSize - 1) / workGroupSize;
    
    glDispatchCompute(numWorkGroups, 1, 1);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
    
    m_computeProgram->release();
    
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, m_particleSSBO);
    void* ptr = glMapBuffer(GL_SHADER_STORAGE_BUFFER, GL_READ_ONLY);
    if (ptr) {
        memcpy(m_particles.data(), ptr, m_particles.size() * sizeof(BoidParticle));
        glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
    }
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
}

void BoidsWidget::updateUniformBuffer() {
    BoidsUniformData uniforms;
    uniforms.resolution[0] = static_cast<float>(m_viewportWidth);
    uniforms.resolution[1] = static_cast<float>(m_viewportHeight);
    uniforms.time = m_time;
    uniforms.deltaTime = 1.0f / 60.0f;
    uniforms.fishColor[0] = m_particleColor.r;
    uniforms.fishColor[1] = m_particleColor.g;
    uniforms.fishColor[2] = m_particleColor.b;
    uniforms.fishColor[3] = m_particleColor.a;
    uniforms.backgroundColor[0] = m_backgroundColor.r;
    uniforms.backgroundColor[1] = m_backgroundColor.g;
    uniforms.backgroundColor[2] = m_backgroundColor.b;
    uniforms.backgroundColor[3] = m_backgroundColor.a;
    uniforms.numFish = m_particleCount;
    uniforms.padding1 = 0;
    uniforms.padding2 = 0;
    uniforms.padding3 = 0;
    
    glBindBuffer(GL_UNIFORM_BUFFER, m_uniformUBO);
    glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(BoidsUniformData), &uniforms);
    glBindBuffer(GL_UNIFORM_BUFFER, 0);
}

} // namespace jules
