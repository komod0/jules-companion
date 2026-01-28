/**
 * OpenGL Text Rendering Spike - Main Application
 * 
 * Proof of concept for GPU-accelerated text rendering on Linux.
 * Validates the OpenGL + FreeType approach for the Jules Linux port.
 * 
 * Acceptance criteria:
 * - Render "Hello World" with proper text metrics
 * - Achieve 60fps for 10,000 characters
 * - Work on both X11 and Wayland
 */

#include <QApplication>
#include <QMainWindow>
#include <QVBoxLayout>
#include <QLabel>
#include <QTimer>
#include <QElapsedTimer>
#include <QDebug>
#include <QPushButton>
#include <QMessageBox>

#include "rendering/opengl_widget.h"

#include <sstream>
#include <iomanip>

namespace {

/**
 * Generate test text with specified character count.
 * Used to benchmark rendering performance.
 */
std::string generateTestText(int charCount) {
    std::stringstream ss;
    
    // Add header
    ss << "=== OpenGL Text Rendering Spike ===\n";
    ss << "Target: 60fps with 10,000+ characters\n";
    ss << "Backend: FreeType + OpenGL 3.3 Core\n";
    ss << "Rendering: Instanced quad drawing\n\n";
    
    // Add code-like content to simulate diff rendering
    const char* sampleCode[] = {
        "int main(int argc, char** argv) {",
        "    // Initialize the application",
        "    QApplication app(argc, argv);",
        "    ",
        "    // Create main window",
        "    jules::OpenGLTextWidget widget;",
        "    widget.setText(\"Hello World\");",
        "    widget.show();",
        "    ",
        "    // Run event loop",
        "    return app.exec();",
        "}",
        "",
        "// Performance metrics:",
        "// - 10,000 characters target",
        "// - Single draw call via instancing",
        "// - R8 font atlas texture",
        "// - GPU-accelerated rendering",
        "",
    };
    
    int currentChars = static_cast<int>(ss.str().length());
    int lineIndex = 0;
    
    while (currentChars < charCount) {
        int idx = lineIndex % (sizeof(sampleCode) / sizeof(sampleCode[0]));
        ss << sampleCode[idx] << "\n";
        currentChars = static_cast<int>(ss.str().length());
        lineIndex++;
    }
    
    return ss.str();
}

/**
 * Demo window containing the OpenGL widget and status display.
 */
class DemoWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit DemoWindow(QWidget* parent = nullptr)
        : QMainWindow(parent)
    {
        setWindowTitle("OpenGL Text Rendering Spike");
        setMinimumSize(800, 600);
        
        // Central widget with layout
        QWidget* central = new QWidget(this);
        QVBoxLayout* layout = new QVBoxLayout(central);
        layout->setContentsMargins(0, 0, 0, 0);
        layout->setSpacing(0);
        
        // Status bar at top
        QWidget* statusBar = new QWidget();
        QHBoxLayout* statusLayout = new QHBoxLayout(statusBar);
        statusLayout->setContentsMargins(10, 5, 10, 5);
        
        m_fpsLabel = new QLabel("FPS: --");
        m_charCountLabel = new QLabel("Characters: 0");
        m_instanceCountLabel = new QLabel("Instances: 0");
        
        QPushButton* btnHelloWorld = new QPushButton("Hello World");
        QPushButton* btn1k = new QPushButton("1K Chars");
        QPushButton* btn10k = new QPushButton("10K Chars");
        QPushButton* btn50k = new QPushButton("50K Chars");
        
        statusLayout->addWidget(m_fpsLabel);
        statusLayout->addWidget(m_charCountLabel);
        statusLayout->addWidget(m_instanceCountLabel);
        statusLayout->addStretch();
        statusLayout->addWidget(btnHelloWorld);
        statusLayout->addWidget(btn1k);
        statusLayout->addWidget(btn10k);
        statusLayout->addWidget(btn50k);
        
        statusBar->setStyleSheet("background-color: #2d2d2d; color: #e0e0e0;");
        
        // OpenGL widget
        m_glWidget = new jules::OpenGLTextWidget();
        
        layout->addWidget(statusBar);
        layout->addWidget(m_glWidget, 1);
        
        setCentralWidget(central);
        
        // Connect buttons
        connect(btnHelloWorld, &QPushButton::clicked, this, [this]() {
            setTestText("Hello World!\n\nThis is the OpenGL text rendering spike.\n\nPress the buttons above to test performance with more characters.");
        });
        
        connect(btn1k, &QPushButton::clicked, this, [this]() {
            setTestText(generateTestText(1000));
        });
        
        connect(btn10k, &QPushButton::clicked, this, [this]() {
            setTestText(generateTestText(10000));
        });
        
        connect(btn50k, &QPushButton::clicked, this, [this]() {
            setTestText(generateTestText(50000));
        });
        
        // FPS update timer
        QTimer* fpsTimer = new QTimer(this);
        connect(fpsTimer, &QTimer::timeout, this, &DemoWindow::updateFpsDisplay);
        fpsTimer->start(500);  // Update every 500ms
        
        // Set initial text
        setTestText("Hello World!\n\nOpenGL Text Rendering Spike\n\nPress buttons above to test performance.");
    }
    
private slots:
    void updateFpsDisplay() {
        m_fpsLabel->setText(QString("FPS: %1").arg(m_glWidget->fps(), 0, 'f', 1));
    }

private:
    void setTestText(const std::string& text) {
        m_glWidget->setText(text);
        m_charCountLabel->setText(QString("Characters: %1").arg(text.length()));
        
        // Count non-whitespace (approximate instance count)
        int nonWs = 0;
        for (char c : text) {
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
                nonWs++;
            }
        }
        m_instanceCountLabel->setText(QString("Instances: ~%1").arg(nonWs));
    }
    
    jules::OpenGLTextWidget* m_glWidget = nullptr;
    QLabel* m_fpsLabel = nullptr;
    QLabel* m_charCountLabel = nullptr;
    QLabel* m_instanceCountLabel = nullptr;
};

} // namespace

// MOC include for local Q_OBJECT
#include "opengl_spike_main.moc"

int main(int argc, char** argv) {
    // Set OpenGL surface format before QApplication
    QSurfaceFormat format;
    format.setVersion(3, 3);
    format.setProfile(QSurfaceFormat::CoreProfile);
    format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
    format.setSwapInterval(1);  // VSync enabled
    QSurfaceFormat::setDefaultFormat(format);
    
    QApplication app(argc, argv);
    
    // Report display server type
    QString platform = QGuiApplication::platformName();
    qDebug() << "Platform:" << platform;
    
    if (platform == "wayland") {
        qDebug() << "Running on Wayland";
    } else if (platform == "xcb") {
        qDebug() << "Running on X11 (XCB)";
    }
    
    DemoWindow window;
    window.show();
    
    return app.exec();
}
