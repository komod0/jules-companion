#include "ui/diff_panel_widget.h"
#include "ui/app_colors.h"
#include "data/settings_manager.h"

#include <QFile>
#include <QDebug>
#include <QOpenGLContext>
#include <QWindow>
#include <QOpenGLShader>
#include <QApplication>
#include <QClipboard>
#include <QMenu>
#include <QAction>
#include <QContextMenuEvent>
#include <cmath>
#include <stdexcept>
#include <random>

namespace jules {

namespace {

// Unit quad vertices (0,0 to 1,1)
// Triangle strip or Triangles?
// BoidsWidget uses 6 vertices for GL_TRIANGLES.
// Text shader expects unit quad: (0,0), (1,0), (0,1), (1,0), (1,1), (0,1)
static constexpr float kQuadVertices[] = {
    0.0f, 0.0f,
    1.0f, 0.0f,
    0.0f, 1.0f,
    1.0f, 0.0f,
    1.0f, 1.0f,
    0.0f, 1.0f,
};

QString loadShaderSource(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        // Try resource path if direct path fails
        if (!path.startsWith(":/")) {
            QFile resFile(":" + path);
            if (resFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
                return QString::fromUtf8(resFile.readAll());
            }
        }
        qWarning() << "Failed to load shader:" << path;
        return {};
    }
    return QString::fromUtf8(file.readAll());
}

} // namespace

DiffPanelWidget::DiffPanelWidget(QWidget* parent)
    : QOpenGLWidget(parent)
{
    QSurfaceFormat format;
    format.setVersion(4, 3);
    format.setProfile(QSurfaceFormat::CoreProfile);
    format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
    format.setSwapInterval(1);
    format.setAlphaBufferSize(0); // No alpha channel — prevents transparency bleed
    setFormat(format);

    // Prevent Qt from compositing this widget with transparency
    setAttribute(Qt::WA_OpaquePaintEvent);
    setAttribute(Qt::WA_NoSystemBackground);
    setAutoFillBackground(false);

    // Enable mouse tracking for selection support
    setMouseTracking(true);
    setFocusPolicy(Qt::ClickFocus);
    
    // Set size policy to expand
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    setMinimumSize(200, 200);

    // Overlay scrollbar
    m_scrollBar = new QScrollBar(Qt::Vertical, this);
    m_scrollBar->setMinimum(0);
    m_scrollBar->setValue(0);
    m_scrollBar->setSingleStep(40);
    m_scrollBar->setPageStep(400);
    m_scrollBar->setStyleSheet(R"(
        QScrollBar:vertical { width: 10px; background: transparent; border: none; }
        QScrollBar::handle:vertical { background: rgba(128, 128, 128, 100); border-radius: 5px; min-height: 30px; }
        QScrollBar::handle:vertical:hover { background: rgba(128, 128, 128, 160); }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
        QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: transparent; }
    )");
    connect(m_scrollBar, &QScrollBar::valueChanged, this, [this](int value) {
        m_scrollOffset = static_cast<float>(value);
        update();
    });

    m_syntaxTimer = new QTimer(this);
    m_syntaxTimer->setInterval(100); // 10 FPS poll for syntax
    connect(m_syntaxTimer, &QTimer::timeout, this, [this]() {
        if (m_diffRenderer && m_diffRenderer->isSyntaxHighlightingComplete()) {
            m_syntaxTimer->stop();
            qDebug() << "[DiffPanelWidget] Syntax highlighting complete, repainting";
            update();
        }
    });

    qDebug() << "[DiffPanelWidget] Constructor called";
}

DiffPanelWidget::~DiffPanelWidget() {
    if (m_initialized) {
        makeCurrent();
        m_rectVao.destroy();
        m_textVao.destroy();
        m_quadBuffer.destroy();
        m_rectInstanceBuffer.destroy();
        m_textInstanceBuffer.destroy();
        m_rectShader.reset();
        m_textShader.reset();
        doneCurrent();
    }
}

void DiffPanelWidget::releaseResources() {
    if (!m_initialized) return;

    makeCurrent();

    m_rectVao.destroy();
    m_textVao.destroy();
    m_quadBuffer.destroy();
    m_rectInstanceBuffer.destroy();
    m_textInstanceBuffer.destroy();
    m_rectShader.reset();
    m_textShader.reset();
    m_diffRenderer.reset();
    m_fontAtlas.reset();

    doneCurrent();

    m_initialized = false;
    m_needsReinit = true;

    if (m_loadingTimer && m_loadingTimer->isActive()) {
        m_loadingTimer->stop();
    }

    qDebug() << "[DiffPanelWidget] Resources released for memory savings";
}

void DiffPanelWidget::updateTheme() {
    const auto& colors = AppColors::currentColors();
    m_isDark = colors.isDark;

    if (m_diffRenderer) {
        auto toRgba = [](const QColor& c) {
            return RGBA{c.redF(), c.greenF(), c.blueF(), c.alphaF()};
        };

        makeCurrent();
        m_diffRenderer->setTheme(
            toRgba(colors.background),
            toRgba(colors.backgroundSecondary),
            toRgba(colors.backgroundDark),
            toRgba(colors.textPrimary),
            toRgba(colors.textSecondary),
            toRgba(colors.accent),
            toRgba(colors.separator),
            colors.isDark
        );

        if (!m_diffRenderer->isSyntaxHighlightingComplete()) {
            m_syntaxTimer->start();
        }

        doneCurrent();
    }
    update();
}

void DiffPanelWidget::updateDarkMode(bool isDark) {
    // For backwards compatibility and testing
    AppColors::setCurrentTheme(isDark ? Theme::Dark : Theme::Light);
    updateTheme();
}

void DiffPanelWidget::setLoading(bool loading) {
    if (m_isLoading == loading) return;

    m_isLoading = loading;

    if (loading) {
        if (m_initialized) {
            startUnderwaterAnimation();
        }
        // else: deferred — initializeGL() will start it
        qDebug() << "[DiffPanelWidget] Loading state started with underwater scene";
    } else {
        stopUnderwaterAnimation();
        qDebug() << "[DiffPanelWidget] Loading state ended";
    }

    update();
}

void DiffPanelWidget::startUnderwaterAnimation() {
    if (!m_loadingTimer) {
        m_loadingTimer = new QTimer(this);
        connect(m_loadingTimer, &QTimer::timeout, this, [this]() {
            updateBubbles(0.016f);
            updateFish(0.016f);
            update();
        });
    }
    if (!m_loadingTimer->isActive()) {
        m_loadingElapsed.start();
        initBubbles();
        initFish();
        m_loadingTimer->start(16); // ~60 FPS
    }
}

void DiffPanelWidget::stopUnderwaterAnimation() {
    if (m_loadingTimer && m_loadingTimer->isActive()) {
        m_loadingTimer->stop();
    }
    m_bubbles.clear();
    m_fish.clear();
}

void DiffPanelWidget::initBubbles() {
    m_bubbles.clear();
    
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> xDist(0.1f, 0.9f);
    std::uniform_real_distribution<float> yDist(0.0f, 1.2f); // Some start below viewport
    std::uniform_real_distribution<float> sizeDist(3.0f, 12.0f);
    std::uniform_real_distribution<float> speedDist(20.0f, 60.0f);
    std::uniform_real_distribution<float> wobbleDist(0.0f, 6.28f);
    std::uniform_real_distribution<float> ampDist(5.0f, 15.0f);
    
    const int numBubbles = 40;
    m_bubbles.reserve(numBubbles);
    
    for (int i = 0; i < numBubbles; ++i) {
        Bubble b;
        b.x = xDist(gen);
        b.y = yDist(gen);
        b.size = sizeDist(gen);
        b.speed = speedDist(gen);
        b.wobblePhase = wobbleDist(gen);
        b.wobbleAmp = ampDist(gen);
        m_bubbles.push_back(b);
    }
}

void DiffPanelWidget::updateBubbles(float deltaTime) {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> xDist(0.1f, 0.9f);
    std::uniform_real_distribution<float> sizeDist(3.0f, 12.0f);
    std::uniform_real_distribution<float> speedDist(20.0f, 60.0f);
    std::uniform_real_distribution<float> wobbleDist(0.0f, 6.28f);
    std::uniform_real_distribution<float> ampDist(5.0f, 15.0f);
    
    for (auto& b : m_bubbles) {
        // Rise upward
        b.y -= (b.speed * deltaTime) / m_viewportHeight;
        
        // Update wobble phase
        b.wobblePhase += deltaTime * 3.0f;
        
        // Respawn at bottom if off top
        if (b.y < -0.1f) {
            b.x = xDist(gen);
            b.y = 1.1f;
            b.size = sizeDist(gen);
            b.speed = speedDist(gen);
            b.wobblePhase = wobbleDist(gen);
            b.wobbleAmp = ampDist(gen);
        }
    }
}

void DiffPanelWidget::initFish() {
    m_fish.clear();

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> xDist(-0.2f, 1.2f);
    std::uniform_real_distribution<float> yDist(0.1f, 0.9f);
    std::uniform_real_distribution<float> sizeDist(8.0f, 18.0f);
    std::uniform_real_distribution<float> speedDist(30.0f, 80.0f);
    std::uniform_real_distribution<float> phaseDist(0.0f, 6.28f);
    std::uniform_real_distribution<float> dirDist(-1.0f, 1.0f);

    const int numFish = 20;
    m_fish.reserve(numFish);

    for (int i = 0; i < numFish; ++i) {
        Fish f;
        f.x = xDist(gen) * m_viewportWidth;
        f.y = yDist(gen) * m_viewportHeight;
        f.swimSpeed = speedDist(gen);
        float angle = phaseDist(gen);
        f.vx = std::cos(angle) * f.swimSpeed;
        f.vy = std::sin(angle) * f.swimSpeed * 0.3f; // Fish swim mostly horizontal
        f.size = sizeDist(gen);
        f.phase = phaseDist(gen);
        m_fish.push_back(f);
    }
}

void DiffPanelWidget::updateFish(float deltaTime) {
    // Simple boids-like behavior: cohesion, separation, alignment
    const float separationDist = 40.0f;
    const float alignDist = 100.0f;
    const float cohesionDist = 150.0f;
    const float separationWeight = 2.0f;
    const float alignWeight = 0.5f;
    const float cohesionWeight = 0.3f;
    const float maxSpeed = 120.0f;
    const float margin = 50.0f;

    for (size_t i = 0; i < m_fish.size(); ++i) {
        Fish& f = m_fish[i];
        float sepX = 0, sepY = 0;
        float alignVx = 0, alignVy = 0;
        float cohX = 0, cohY = 0;
        int sepCount = 0, alignCount = 0, cohCount = 0;

        for (size_t j = 0; j < m_fish.size(); ++j) {
            if (i == j) continue;
            float dx = m_fish[j].x - f.x;
            float dy = m_fish[j].y - f.y;
            float dist = std::sqrt(dx * dx + dy * dy);

            if (dist < separationDist && dist > 0.1f) {
                sepX -= dx / dist;
                sepY -= dy / dist;
                sepCount++;
            }
            if (dist < alignDist) {
                alignVx += m_fish[j].vx;
                alignVy += m_fish[j].vy;
                alignCount++;
            }
            if (dist < cohesionDist) {
                cohX += m_fish[j].x;
                cohY += m_fish[j].y;
                cohCount++;
            }
        }

        float ax = 0, ay = 0;
        if (sepCount > 0) { ax += sepX * separationWeight; ay += sepY * separationWeight; }
        if (alignCount > 0) { ax += (alignVx / alignCount - f.vx) * alignWeight; ay += (alignVy / alignCount - f.vy) * alignWeight; }
        if (cohCount > 0) { ax += (cohX / cohCount - f.x) * cohesionWeight * 0.01f; ay += (cohY / cohCount - f.y) * cohesionWeight * 0.01f; }

        // Boundary avoidance: steer back into viewport
        if (f.x < margin) ax += 20.0f;
        if (f.x > m_viewportWidth - margin) ax -= 20.0f;
        if (f.y < margin) ay += 20.0f;
        if (f.y > m_viewportHeight - margin) ay -= 20.0f;

        f.vx += ax * deltaTime;
        f.vy += ay * deltaTime;

        // Clamp speed
        float speed = std::sqrt(f.vx * f.vx + f.vy * f.vy);
        if (speed > maxSpeed) {
            f.vx = f.vx / speed * maxSpeed;
            f.vy = f.vy / speed * maxSpeed;
        }
        // Minimum speed
        if (speed < 15.0f && speed > 0.1f) {
            f.vx = f.vx / speed * 15.0f;
            f.vy = f.vy / speed * 15.0f;
        }

        f.x += f.vx * deltaTime;
        f.y += f.vy * deltaTime;
        f.phase += deltaTime * 8.0f; // Tail wiggle
    }
}

void DiffPanelWidget::setDiffs(const QList<CachedDiff>& diffs) {
    qDebug() << "[DiffPanelWidget::setDiffs] Received" << diffs.size() << "diffs, initialized=" << m_initialized;

    std::vector<DiffSection> sections;
    sections.reserve(diffs.size());

    for (const auto& diff : diffs) {
        DiffSection section;
        section.patch = diff.patch.toStdString();
        section.language = diff.language.value_or("").toStdString();
        section.filename = diff.filename.value_or("").toStdString();
        qDebug() << "[DiffPanelWidget::setDiffs] Diff file:" << diff.filename.value_or("(no filename)")
                 << "patch length:" << diff.patch.length();
        sections.push_back(section);
    }

    // Stop underwater animation when real diffs arrive
    // (animation is managed by setLoading(), not by setDiffs())
    if (!diffs.isEmpty()) {
        stopUnderwaterAnimation();
    }

    if (m_diffRenderer) {
        qDebug() << "[DiffPanelWidget::setDiffs] Passing" << sections.size() << "sections to renderer";
        m_diffRenderer->setDiffSections(sections);
        m_scrollOffset = 0.0f;
        updateScrollBar();

        // Start polling for syntax highlighting
        if (!m_diffRenderer->isSyntaxHighlightingComplete()) {
            m_syntaxTimer->start();
        }

        update(); // Trigger repaint
    } else {
        // Store for later when renderer is initialized
        qDebug() << "[DiffPanelWidget::setDiffs] Renderer not ready, storing" << sections.size() << "pending sections";
        m_pendingDiffs = std::move(sections);
    }
}

void DiffPanelWidget::initializeGL() {
    qDebug() << "[DiffPanelWidget::initializeGL] Starting initialization";
    if (m_initialized) {
        qDebug() << "[DiffPanelWidget::initializeGL] Already initialized";
        return;
    }

    try {
        if (!initializeOpenGLFunctions()) {
            qWarning() << "Failed to initialize OpenGL 4.3 functions";
            m_glFailed = true;
            emit openglFailed("OpenGL 4.3 not supported");
            return;
        }
        qDebug() << "[DiffPanelWidget::initializeGL] OpenGL functions initialized";

        // Initialize renderer components
        m_diffRenderer = std::make_unique<DiffRenderer>();
        if (!m_diffRenderer->initialize()) {
            qWarning() << "Failed to initialize DiffRenderer";
            m_glFailed = true;
            emit openglFailed("DiffRenderer initialization failed");
            return;
        }
        qDebug() << "[DiffPanelWidget::initializeGL] DiffRenderer initialized";

        m_fontAtlas = std::make_unique<FontAtlas>();
        // Use font size from settings
        float fontSize = static_cast<float>(SettingsManager::instance().diffFontSize());
        if (!m_fontAtlas->initialize(fontSize, m_devicePixelRatio)) {
            qWarning() << "Failed to initialize FontAtlas";
            m_glFailed = true;
            emit openglFailed("FontAtlas initialization failed");
            return;
        }
        qDebug() << "[DiffPanelWidget::initializeGL] FontAtlas initialized";

        if (!loadShaders()) {
            qWarning() << "[DiffPanelWidget::initializeGL] Failed to load shaders";
            m_glFailed = true;
            emit openglFailed("Shader compilation failed");
            return;
        }
        qDebug() << "[DiffPanelWidget::initializeGL] Shaders loaded";

        setupBuffers();

        m_initialized = true;
        qDebug() << "[DiffPanelWidget::initializeGL] Fully initialized";

        // Set initial theme colors
        updateTheme();

        // Apply any pending diffs that were set before initialization
        if (!m_pendingDiffs.empty()) {
            qDebug() << "[DiffPanelWidget::initializeGL] Applying" << m_pendingDiffs.size() << "pending diffs";
            m_diffRenderer->setDiffSections(m_pendingDiffs);
            m_pendingDiffs.clear();
            updateScrollBar();
            update();
        }

        // Start deferred loading animation if loading was requested before GL init
        if (m_isLoading) {
            qDebug() << "[DiffPanelWidget::initializeGL] Starting deferred loading animation";
            startUnderwaterAnimation();
        }
    } catch (const std::exception& e) {
        qWarning() << "[DiffPanelWidget::initializeGL] Exception:" << e.what();
        m_glFailed = true;
        emit openglFailed(QString("OpenGL init exception: %1").arg(e.what()));
    }
}

void DiffPanelWidget::resizeGL(int w, int h) {
    m_viewportWidth = w;
    m_viewportHeight = h;

    if (!m_initialized) {
        return;  // GL not ready yet — skip until initializeGL completes
    }

    // Get device pixel ratio from window handle if possible, default to stored
    if (window() && window()->windowHandle()) {
        m_devicePixelRatio = window()->windowHandle()->devicePixelRatio();
    }

    glViewport(0, 0, static_cast<int>(w * m_devicePixelRatio),
               static_cast<int>(h * m_devicePixelRatio));

    if (m_diffRenderer) {
        m_diffRenderer->setViewportSize(w, h, m_devicePixelRatio);
    }

    updateScrollBar();
}

void DiffPanelWidget::paintGL() {
    // Use theme background for GL clear color
    const auto& tc = AppColors::currentColors();
    float bgR = tc.background.redF(), bgG = tc.background.greenF(), bgB = tc.background.blueF();

    if (m_glFailed) {
        glClearColor(bgR, bgG, bgB, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        return;
    }

    if (m_needsReinit) {
        initializeGL();
        m_needsReinit = false;
    }

    glClearColor(bgR, bgG, bgB, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    if (!m_initialized || !m_diffRenderer) {
        return;
    }

    // If loading, render a spinner instead of diff content
    if (m_isLoading) {
        renderLoadingSpinner();
        return;
    }

    int sectionCount = m_diffRenderer->sectionCount();

    // Empty state: no diffs and not loading
    if (sectionCount == 0) {
        renderEmptyState();
        return;
    }
    static int lastLoggedCount = -1;
    if (sectionCount != lastLoggedCount) {
        qDebug() << "[DiffPanelWidget::paintGL] sections=" << sectionCount 
                 << "viewport=" << m_viewportWidth << "x" << m_viewportHeight;
        lastLoggedCount = sectionCount;
    }

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDisable(GL_DEPTH_TEST); // 2D rendering, no depth needed

    // Generate render data (reuse persistent buffer via move to avoid reallocation)
    float viewportTop = m_scrollOffset;
    float viewportBottom = m_scrollOffset + m_viewportHeight;
    m_renderResult = m_diffRenderer->generateRenderData(viewportTop, viewportBottom);

    // 1. Draw Background Rectangles
    if (!m_renderResult.rectInstances.empty()) {
        m_rectShader->bind();
        m_rectShader->setUniformValue("u_viewportSize", QVector2D(m_viewportWidth, m_viewportHeight));
        m_rectShader->setUniformValue("u_camera", QVector2D(0.0f, m_scrollOffset));
        m_rectShader->setUniformValue("u_scale", m_devicePixelRatio);

        m_rectVao.bind();
        
        // Update instance buffer
        m_rectInstanceBuffer.bind();
        m_rectInstanceBuffer.allocate(m_renderResult.rectInstances.data(),
            static_cast<int>(m_renderResult.rectInstances.size() * sizeof(DiffRectInstance)));

        glDrawArraysInstanced(GL_TRIANGLES, 0, 6, static_cast<int>(m_renderResult.rectInstances.size()));
        
        m_rectInstanceBuffer.release();
        m_rectVao.release();
        m_rectShader->release();
    }

    // 2. Draw Text (Normal and Bold)
    if ((!m_renderResult.textInstances.empty() || !m_renderResult.boldInstances.empty()) && m_fontAtlas) {
        m_textShader->bind();
        m_textShader->setUniformValue("u_viewportSize", QVector2D(m_viewportWidth, m_viewportHeight));
        m_textShader->setUniformValue("u_camera", QVector2D(0.0f, m_scrollOffset));
        m_textShader->setUniformValue("u_atlas", 0); // Texture unit 0

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, m_fontAtlas->textureId());

        m_textVao.bind();
        m_textInstanceBuffer.bind();

        // Draw normal text
        if (!m_renderResult.textInstances.empty()) {
            m_textInstanceBuffer.allocate(m_renderResult.textInstances.data(),
                static_cast<int>(m_renderResult.textInstances.size() * sizeof(DiffInstanceData)));
            glDrawArraysInstanced(GL_TRIANGLES, 0, 6, static_cast<int>(m_renderResult.textInstances.size()));
        }

        // Draw bold text (reuses same shader/setup for now, just different instances)
        if (!m_renderResult.boldInstances.empty()) {
            m_textInstanceBuffer.allocate(m_renderResult.boldInstances.data(),
                static_cast<int>(m_renderResult.boldInstances.size() * sizeof(DiffInstanceData)));
            glDrawArraysInstanced(GL_TRIANGLES, 0, 6, static_cast<int>(m_renderResult.boldInstances.size()));
        }

        m_textInstanceBuffer.release();
        m_textVao.release();
        
        glBindTexture(GL_TEXTURE_2D, 0);
        m_textShader->release();
    }
}

void DiffPanelWidget::wheelEvent(QWheelEvent* event) {
    if (!m_diffRenderer) return;

    float delta = event->angleDelta().y();
    // Typical mouse wheel is 120 units per notch. 
    // We want reasonable scroll speed. 
    // On macOS precision trackpads return smaller values.
    
    m_scrollOffset -= delta;

    // Clamp scrolling
    float totalHeight = m_diffRenderer->totalContentHeight();
    float maxScroll = std::max(0.0f, totalHeight - m_viewportHeight);
    
    m_scrollOffset = std::max(0.0f, std::min(m_scrollOffset, maxScroll));

    if (m_scrollBar) {
        m_scrollBar->blockSignals(true);
        m_scrollBar->setValue(static_cast<int>(m_scrollOffset));
        m_scrollBar->blockSignals(false);
    }

    update();
}

TextPosition DiffPanelWidget::pixelToTextPosition(const QPoint& pos) const {
    float dpr = m_devicePixelRatio;
    float y = pos.y() * dpr + m_scrollOffset;
    float x = pos.x() * dpr;
    int line = static_cast<int>(y / m_diffRenderer->lineHeight());
    int col = static_cast<int>((x - DiffRenderer::kGutterWidth) / m_diffRenderer->monoAdvance());
    return {line, std::max(0, col)};
}

void DiffPanelWidget::mousePressEvent(QMouseEvent* event) {
    if (!m_diffRenderer || event->button() != Qt::LeftButton) {
        QOpenGLWidget::mousePressEvent(event);
        return;
    }

    m_diffRenderer->clearSelection();
    m_selectionStart = pixelToTextPosition(event->pos());
    m_isSelecting = true;
    update();
}

void DiffPanelWidget::mouseMoveEvent(QMouseEvent* event) {
    if (!m_diffRenderer || !m_isSelecting) {
        QOpenGLWidget::mouseMoveEvent(event);
        return;
    }

    TextPosition current = pixelToTextPosition(event->pos());
    m_diffRenderer->setSelection(m_selectionStart, current);
    update();
}

void DiffPanelWidget::mouseReleaseEvent(QMouseEvent* event) {
    if (event->button() == Qt::LeftButton) {
        m_isSelecting = false;
    }
    QOpenGLWidget::mouseReleaseEvent(event);
}

void DiffPanelWidget::keyPressEvent(QKeyEvent* event) {
    if (!m_diffRenderer) {
        QOpenGLWidget::keyPressEvent(event);
        return;
    }

    if (event->matches(QKeySequence::Copy)) {
        std::string text = m_diffRenderer->selectedText();
        if (!text.empty()) {
            QApplication::clipboard()->setText(QString::fromStdString(text));
        }
        return;
    }

    if (event->key() == Qt::Key_Escape) {
        m_diffRenderer->clearSelection();
        update();
        return;
    }

    QOpenGLWidget::keyPressEvent(event);
}

void DiffPanelWidget::contextMenuEvent(QContextMenuEvent* event) {
    QMenu menu(this);

    // Copy Selection (enabled only when text is selected)
    QAction* copyAction = menu.addAction("Copy Selection");
    copyAction->setShortcut(QKeySequence::Copy);
    bool hasSelection = m_diffRenderer && !m_diffRenderer->selectedText().empty();
    copyAction->setEnabled(hasSelection);
    connect(copyAction, &QAction::triggered, this, [this]() {
        std::string text = m_diffRenderer->selectedText();
        if (!text.empty()) {
            QApplication::clipboard()->setText(QString::fromStdString(text));
        }
    });

    // Copy File Path
    QString filename = sectionFilenameAt(event->pos());
    QAction* copyPathAction = menu.addAction("Copy File Path");
    copyPathAction->setEnabled(!filename.isEmpty());
    connect(copyPathAction, &QAction::triggered, this, [filename]() {
        QApplication::clipboard()->setText(filename);
    });

    // Select All
    QAction* selectAllAction = menu.addAction("Select All");
    connect(selectAllAction, &QAction::triggered, this, [this]() {
        if (m_diffRenderer) {
            m_diffRenderer->selectAll();
            update();
        }
    });

    menu.exec(event->globalPos());
}

QString DiffPanelWidget::sectionFilenameAt(const QPoint& pos) const {
    if (!m_diffRenderer) return {};
    float worldY = pos.y() + m_scrollOffset;
    int sectionIdx = m_diffRenderer->sectionIndexAtY(worldY);
    if (sectionIdx < 0) return {};
    return QString::fromStdString(m_diffRenderer->sectionFilename(sectionIdx));
}

bool DiffPanelWidget::loadShaders() {
    // Load Rect Shader
    m_rectShader = std::make_unique<QOpenGLShaderProgram>();
    if (!m_rectShader->addShaderFromSourceCode(QOpenGLShader::Vertex, loadShaderSource("shaders/rect.vert")) ||
        !m_rectShader->addShaderFromSourceCode(QOpenGLShader::Fragment, loadShaderSource("shaders/rect.frag")) ||
        !m_rectShader->link()) {
        qWarning() << "Rect shader failed:" << m_rectShader->log();
        return false;
    }

    // Load Text Shader
    m_textShader = std::make_unique<QOpenGLShaderProgram>();
    if (!m_textShader->addShaderFromSourceCode(QOpenGLShader::Vertex, loadShaderSource("shaders/text.vert")) ||
        !m_textShader->addShaderFromSourceCode(QOpenGLShader::Fragment, loadShaderSource("shaders/text.frag")) ||
        !m_textShader->link()) {
        qWarning() << "Text shader failed:" << m_textShader->log();
        return false;
    }

    return true;
}

void DiffPanelWidget::setupBuffers() {
    // Setup Quad Buffer (shared)
    m_quadBuffer.create();
    m_quadBuffer.bind();
    m_quadBuffer.allocate(kQuadVertices, sizeof(kQuadVertices));
    m_quadBuffer.release();

    // Setup Rect VAO
    m_rectVao.create();
    m_rectVao.bind();
    m_quadBuffer.bind();
    
    // a_position (loc 0)
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), nullptr);
    
    m_rectInstanceBuffer.create();
    m_rectInstanceBuffer.bind();
    
    // Stride is sizeof(DiffRectInstance) = 64 bytes
    GLsizei rectStride = sizeof(DiffRectInstance);
    
    // i_origin (loc 1, vec2)
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, rectStride, (void*)offsetof(DiffRectInstance, originX));
    glVertexAttribDivisor(1, 1);
    
    // i_size (loc 2, vec2)
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, rectStride, (void*)offsetof(DiffRectInstance, sizeX));
    glVertexAttribDivisor(2, 1);
    
    // i_color (loc 3, vec4)
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 4, GL_FLOAT, GL_FALSE, rectStride, (void*)offsetof(DiffRectInstance, colorR));
    glVertexAttribDivisor(3, 1);
    
    // i_cornerRadius (loc 4, float)
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 1, GL_FLOAT, GL_FALSE, rectStride, (void*)offsetof(DiffRectInstance, cornerRadius));
    glVertexAttribDivisor(4, 1);
    
    // i_borderWidth (loc 5, float)
    glEnableVertexAttribArray(5);
    glVertexAttribPointer(5, 1, GL_FLOAT, GL_FALSE, rectStride, (void*)offsetof(DiffRectInstance, borderWidth));
    glVertexAttribDivisor(5, 1);
    
    // i_borderColor (loc 6, vec4)
    glEnableVertexAttribArray(6);
    glVertexAttribPointer(6, 4, GL_FLOAT, GL_FALSE, rectStride, (void*)offsetof(DiffRectInstance, borderColorR));
    glVertexAttribDivisor(6, 1);
    
    m_rectInstanceBuffer.release();
    m_quadBuffer.release();
    m_rectVao.release();

    // Setup Text VAO
    m_textVao.create();
    m_textVao.bind();
    m_quadBuffer.bind();
    
    // a_position (loc 0)
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), nullptr);
    
    m_textInstanceBuffer.create();
    m_textInstanceBuffer.bind();
    
    // Stride is sizeof(DiffInstanceData) = 12 * 4 = 48 bytes
    GLsizei textStride = sizeof(DiffInstanceData);
    
    // i_origin (loc 1, vec2)
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, textStride, (void*)offsetof(DiffInstanceData, originX));
    glVertexAttribDivisor(1, 1);
    
    // i_size (loc 2, vec2)
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, textStride, (void*)offsetof(DiffInstanceData, sizeX));
    glVertexAttribDivisor(2, 1);
    
    // i_uvMin (loc 3, vec2)
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, textStride, (void*)offsetof(DiffInstanceData, uvMinX));
    glVertexAttribDivisor(3, 1);
    
    // i_uvMax (loc 4, vec2)
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 2, GL_FLOAT, GL_FALSE, textStride, (void*)offsetof(DiffInstanceData, uvMaxX));
    glVertexAttribDivisor(4, 1);
    
    // i_color (loc 5, vec4)
    glEnableVertexAttribArray(5);
    glVertexAttribPointer(5, 4, GL_FLOAT, GL_FALSE, textStride, (void*)offsetof(DiffInstanceData, colorR));
    glVertexAttribDivisor(5, 1);
    
    m_textInstanceBuffer.release();
    m_quadBuffer.release();
    m_textVao.release();
}

void DiffPanelWidget::updateScrollBar() {
    if (!m_scrollBar) return;

    float totalHeight = m_diffRenderer ? m_diffRenderer->totalContentHeight() : 0.0f;
    float maxScroll = std::max(0.0f, totalHeight - m_viewportHeight);

    if (maxScroll <= 0.0f) {
        m_scrollBar->hide();
        return;
    }

    m_scrollBar->show();
    m_scrollBar->setGeometry(width() - 10, 0, 10, height());

    m_scrollBar->blockSignals(true);
    m_scrollBar->setMaximum(static_cast<int>(maxScroll));
    m_scrollBar->setPageStep(m_viewportHeight);
    m_scrollBar->setValue(static_cast<int>(m_scrollOffset));
    m_scrollBar->blockSignals(false);
}

void DiffPanelWidget::renderLoadingSpinner() {
    renderUnderwaterScene();
}

void DiffPanelWidget::renderUnderwaterScene() {
    if (!m_rectShader) return;

    float time = m_loadingElapsed.elapsed() / 1000.0f;
    float w = static_cast<float>(m_viewportWidth);
    float h = static_cast<float>(m_viewportHeight);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    m_rectShader->bind();
    m_rectShader->setUniformValue("u_viewportSize", QVector2D(w, h));
    m_rectShader->setUniformValue("u_camera", QVector2D(0.0f, 0.0f));
    m_rectShader->setUniformValue("u_scale", m_devicePixelRatio);

    // We'll batch all rects into one draw call for efficiency.
    std::vector<DiffRectInstance> rects;
    rects.reserve(m_bubbles.size() + m_fish.size() * 2 + 4);

    // ---- Ocean gradient background (3-4 horizontal bands) ----
    // Deep blue at bottom, slightly lighter mid, darker at top
    float bgR1, bgG1, bgB1, bgR2, bgG2, bgB2, bgR3, bgG3, bgB3;
    if (m_isDark) {
        bgR1 = 0.02f; bgG1 = 0.04f; bgB1 = 0.12f;  // Top: very dark blue
        bgR2 = 0.04f; bgG2 = 0.08f; bgB2 = 0.22f;  // Mid: dark blue
        bgR3 = 0.06f; bgG3 = 0.12f; bgB3 = 0.30f;  // Bottom: slightly brighter
    } else {
        bgR1 = 0.70f; bgG1 = 0.82f; bgB1 = 0.92f;  // Top: light sky blue
        bgR2 = 0.50f; bgG2 = 0.70f; bgB2 = 0.88f;  // Mid: medium blue
        bgR3 = 0.35f; bgG3 = 0.55f; bgB3 = 0.80f;  // Bottom: deeper blue
    }
    // Top band
    { DiffRectInstance r{}; r.originX = 0; r.originY = 0; r.sizeX = w; r.sizeY = h * 0.33f;
      r.colorR = bgR1; r.colorG = bgG1; r.colorB = bgB1; r.colorA = 1.0f; rects.push_back(r); }
    // Middle band
    { DiffRectInstance r{}; r.originX = 0; r.originY = h * 0.33f; r.sizeX = w; r.sizeY = h * 0.34f;
      r.colorR = bgR2; r.colorG = bgG2; r.colorB = bgB2; r.colorA = 1.0f; rects.push_back(r); }
    // Bottom band
    { DiffRectInstance r{}; r.originX = 0; r.originY = h * 0.67f; r.sizeX = w; r.sizeY = h * 0.33f;
      r.colorR = bgR3; r.colorG = bgG3; r.colorB = bgB3; r.colorA = 1.0f; rects.push_back(r); }

    // ---- Rising bubbles ----
    for (const auto& b : m_bubbles) {
        float wobbleX = std::sin(b.wobblePhase) * b.wobbleAmp;
        float screenX = b.x * w + wobbleX;
        float screenY = b.y * h;

        float fadeY = 1.0f;
        if (b.y > 0.9f) fadeY = (1.0f - b.y) / 0.1f;
        if (b.y < 0.1f) fadeY = b.y / 0.1f;

        float shimmer = 0.5f + 0.3f * std::sin(time * 2.0f + b.wobblePhase);
        float bAlpha = m_isDark ? 0.25f : 0.35f;

        DiffRectInstance bubble{};
        bubble.originX = screenX - b.size;
        bubble.originY = screenY - b.size;
        bubble.sizeX = b.size * 2.0f;
        bubble.sizeY = b.size * 2.0f;
        bubble.colorR = 0.5f + shimmer * 0.2f;
        bubble.colorG = 0.7f + shimmer * 0.15f;
        bubble.colorB = 1.0f;
        bubble.colorA = bAlpha * fadeY;
        bubble.cornerRadius = b.size; // Circular
        bubble.borderWidth = 1.0f;
        bubble.borderColorR = 0.7f;
        bubble.borderColorG = 0.85f;
        bubble.borderColorB = 1.0f;
        bubble.borderColorA = 0.4f * fadeY;

        rects.push_back(bubble);
    }

    // ---- Swimming fish (body + tail) ----
    // Each fish is a rounded rect (body) + a smaller triangle-like rect (tail)
    for (const auto& f : m_fish) {
        // Fish facing direction
        float speed = std::sqrt(f.vx * f.vx + f.vy * f.vy);
        float dirX = speed > 0.1f ? f.vx / speed : 1.0f;

        // Tail wiggle offset
        float tailWiggle = std::sin(f.phase) * 3.0f;

        // Fish body colors - vary slightly per fish using phase
        float fishHue = std::fmod(f.phase, 6.28f) / 6.28f;
        float fishR, fishG, fishB;
        if (m_isDark) {
            // Bright warm colors on dark background
            fishR = 0.6f + 0.3f * std::sin(fishHue * 6.28f);
            fishG = 0.5f + 0.3f * std::sin(fishHue * 6.28f + 2.09f);
            fishB = 0.4f + 0.3f * std::sin(fishHue * 6.28f + 4.18f);
        } else {
            // Deeper saturated colors on light background
            fishR = 0.3f + 0.35f * std::sin(fishHue * 6.28f);
            fishG = 0.25f + 0.35f * std::sin(fishHue * 6.28f + 2.09f);
            fishB = 0.2f + 0.35f * std::sin(fishHue * 6.28f + 4.18f);
        }

        float bodyW = f.size;
        float bodyH = f.size * 0.4f;
        float alpha = 0.85f;

        // Body
        DiffRectInstance body{};
        body.originX = f.x - bodyW / 2.0f;
        body.originY = f.y - bodyH / 2.0f;
        body.sizeX = bodyW;
        body.sizeY = bodyH;
        body.colorR = fishR;
        body.colorG = fishG;
        body.colorB = fishB;
        body.colorA = alpha;
        body.cornerRadius = bodyH / 2.0f; // Pill shape
        rects.push_back(body);

        // Tail (smaller rect behind the body)
        float tailSize = bodyH * 0.7f;
        float tailOffsetX = (dirX > 0 ? -1.0f : 1.0f) * bodyW * 0.45f;
        DiffRectInstance tail{};
        tail.originX = f.x + tailOffsetX - tailSize / 2.0f;
        tail.originY = f.y + tailWiggle - tailSize / 2.0f;
        tail.sizeX = tailSize;
        tail.sizeY = tailSize;
        tail.colorR = fishR * 0.8f;
        tail.colorG = fishG * 0.8f;
        tail.colorB = fishB * 0.8f;
        tail.colorA = alpha * 0.7f;
        tail.cornerRadius = tailSize * 0.3f;
        rects.push_back(tail);
    }

    // ---- Draw all rects in one batch ----
    m_rectVao.bind();
    m_rectInstanceBuffer.bind();
    m_rectInstanceBuffer.allocate(rects.data(),
        static_cast<int>(rects.size() * sizeof(DiffRectInstance)));
    glDrawArraysInstanced(GL_TRIANGLES, 0, 6, static_cast<int>(rects.size()));

    m_rectInstanceBuffer.release();
    m_rectVao.release();
    m_rectShader->release();
}

void DiffPanelWidget::renderEmptyState() {
    // Use the same underwater scene animation for empty state
    renderUnderwaterScene();
}

} // namespace jules
