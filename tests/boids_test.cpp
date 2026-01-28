#include <gtest/gtest.h>
#include "rendering/boids_widget.h"

#include <QApplication>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <memory>
#include <cmath>
#include <cstdlib>

namespace {

static QApplication* g_app = nullptr;
static bool g_widgetTestsEnabled = false;

bool initQtApp(int& argc, char** argv) {
    if (g_app) return true;
    
    const char* qtPlatform = std::getenv("QT_QPA_PLATFORM");
    if (!qtPlatform) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
    }
    
    try {
        g_app = new QApplication(argc, argv);
        g_widgetTestsEnabled = true;
        return true;
    } catch (...) {
        return false;
    }
}

class BoidsTestFixture : public ::testing::Test {
protected:
    void SetUp() override {
        if (!g_widgetTestsEnabled) {
            GTEST_SKIP() << "Qt widget tests disabled (no display/offscreen support)";
        }
    }
    
    std::unique_ptr<jules::BoidsWidget> createWidget() {
        try {
            return std::make_unique<jules::BoidsWidget>();
        } catch (...) {
            return nullptr;
        }
    }
    
    static float distance(const jules::BoidParticle& a, const jules::BoidParticle& b) {
        float dx = a.position.x - b.position.x;
        float dy = a.position.y - b.position.y;
        return std::sqrt(dx * dx + dy * dy);
    }
};

}

TEST_F(BoidsTestFixture, BoidsWidgetCanBeConstructed) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget (no display available)";
    }
    EXPECT_FALSE(widget->isInitialized());
}

TEST_F(BoidsTestFixture, BoidsWidgetDefaultSettings) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    EXPECT_EQ(widget->particleCount(), jules::BoidsWidget::kDefaultParticleCount);
    EXPECT_FALSE(widget->isPaused());
}

TEST_F(BoidsTestFixture, BoidsWidgetSetViewportWithoutInit) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    widget->setViewportSize(1920, 1080, 2.0f);
    
    EXPECT_EQ(widget->viewportWidth(), 1920);
    EXPECT_EQ(widget->viewportHeight(), 1080);
    EXPECT_FLOAT_EQ(widget->devicePixelRatio(), 2.0f);
}

TEST_F(BoidsTestFixture, BoidsWidgetSetParticleCountWithoutInit) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    widget->setParticleCount(2000);
    EXPECT_EQ(widget->particleCount(), 2000);
    
    widget->setParticleCount(500);
    EXPECT_EQ(widget->particleCount(), 500);
}

TEST_F(BoidsTestFixture, ParticleCountClampedToReasonableRange) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    widget->setParticleCount(0);
    EXPECT_GE(widget->particleCount(), jules::BoidsWidget::kMinParticleCount);
    
    widget->setParticleCount(1000000);
    EXPECT_LE(widget->particleCount(), jules::BoidsWidget::kMaxParticleCount);
}

TEST_F(BoidsTestFixture, CanSetParticleColor) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    jules::RGBA purple{0.541f, 0.459f, 1.0f, 1.0f};
    widget->setParticleColor(purple);
    
    auto color = widget->particleColor();
    EXPECT_FLOAT_EQ(color.r, 0.541f);
    EXPECT_FLOAT_EQ(color.g, 0.459f);
    EXPECT_FLOAT_EQ(color.b, 1.0f);
    EXPECT_FLOAT_EQ(color.a, 1.0f);
}

TEST_F(BoidsTestFixture, CanSetBackgroundColor) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    jules::RGBA darkGray{0.1f, 0.1f, 0.1f, 1.0f};
    widget->setBackgroundColor(darkGray);
    
    auto color = widget->backgroundColor();
    EXPECT_FLOAT_EQ(color.r, 0.1f);
    EXPECT_FLOAT_EQ(color.g, 0.1f);
    EXPECT_FLOAT_EQ(color.b, 0.1f);
}

TEST_F(BoidsTestFixture, CanSetRenderMode) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    widget->setRenderMode(jules::BoidsRenderMode::Minimal);
    EXPECT_EQ(widget->renderMode(), jules::BoidsRenderMode::Minimal);
    
    widget->setRenderMode(jules::BoidsRenderMode::Full);
    EXPECT_EQ(widget->renderMode(), jules::BoidsRenderMode::Full);
}

TEST_F(BoidsTestFixture, CanPauseAndResumeWithoutInit) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    widget->pause();
    EXPECT_TRUE(widget->isPaused());
    
    widget->resume();
    EXPECT_FALSE(widget->isPaused());
}

TEST_F(BoidsTestFixture, AutoplaySettingControlsInitialPause) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    
    widget->setAutoplay(false);
    EXPECT_TRUE(widget->isPaused());
    
    widget->setAutoplay(true);
    EXPECT_FALSE(widget->isPaused());
}

TEST_F(BoidsTestFixture, InitializeFailsWithoutGLContext) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    EXPECT_FALSE(widget->initialize());
}

TEST_F(BoidsTestFixture, UpdateDoesNothingWhenNotInitialized) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    widget->setParticleCount(100);
    
    auto before = widget->particles();
    widget->update(1.0f / 60.0f);
    auto after = widget->particles();
    
    EXPECT_EQ(before.size(), after.size());
}

TEST_F(BoidsTestFixture, RenderDoesNothingWhenNotInitialized) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    widget->render();
}

TEST_F(BoidsTestFixture, ResetWithoutInit) {
    auto widget = createWidget();
    if (!widget) {
        GTEST_SKIP() << "Cannot construct BoidsWidget";
    }
    widget->setParticleCount(100);
    widget->reset();
}

TEST(BoidsStructTest, Vec2DefaultInitialization) {
    jules::Vec2 v;
    EXPECT_FLOAT_EQ(v.x, 0.0f);
    EXPECT_FLOAT_EQ(v.y, 0.0f);
}

TEST(BoidsStructTest, BoidParticleDefaultInitialization) {
    jules::BoidParticle p;
    EXPECT_FLOAT_EQ(p.position.x, 0.0f);
    EXPECT_FLOAT_EQ(p.position.y, 0.0f);
    EXPECT_FLOAT_EQ(p.velocity.x, 0.0f);
    EXPECT_FLOAT_EQ(p.velocity.y, 0.0f);
}

TEST(BoidsStructTest, RGBADefaultInitialization) {
    jules::RGBA color;
    EXPECT_FLOAT_EQ(color.r, 0.0f);
    EXPECT_FLOAT_EQ(color.g, 0.0f);
    EXPECT_FLOAT_EQ(color.b, 0.0f);
    EXPECT_FLOAT_EQ(color.a, 1.0f);
}

TEST(BoidsEnumTest, RenderModeValues) {
    EXPECT_NE(jules::BoidsRenderMode::Full, jules::BoidsRenderMode::Minimal);
}

int main(int argc, char **argv) {
    ::testing::InitGoogleTest(&argc, argv);
    
    if (!initQtApp(argc, argv)) {
        std::cout << "[  INFO    ] Qt initialization failed, running struct/enum tests only\n";
        ::testing::GTEST_FLAG(filter) = "BoidsStructTest.*:BoidsEnumTest.*";
    }
    
    int result = RUN_ALL_TESTS();
    
    delete g_app;
    g_app = nullptr;
    
    return result;
}
