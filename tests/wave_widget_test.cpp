#include <gtest/gtest.h>
#include "rendering/wave_widget.h"

#include <QApplication>
#include <QOpenGLContext>
#include <QOffscreenSurface>

namespace jules {

class WaveWidgetTestFixture : public ::testing::Test {
protected:
    static bool initQtApp(int& argc, char** argv) {
        if (!QApplication::instance()) {
            static QApplication app(argc, argv);
        }
        return QApplication::instance() != nullptr;
    }
};

TEST_F(WaveWidgetTestFixture, WaveWidgetCreatesSuccessfully) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    EXPECT_FALSE(widget.isInitialized());
    EXPECT_FALSE(widget.shadersValid());
}

TEST_F(WaveWidgetTestFixture, WaveWidgetDefaultPreset) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    EXPECT_EQ(widget.preset(), WavePreset::Default);
    EXPECT_EQ(widget.waveCount(), 3);
}

TEST_F(WaveWidgetTestFixture, WaveWidgetPresetChange) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    
    widget.setPreset(WavePreset::Calm);
    EXPECT_EQ(widget.preset(), WavePreset::Calm);
    EXPECT_EQ(widget.waveCount(), 2);
    
    widget.setPreset(WavePreset::Dramatic);
    EXPECT_EQ(widget.preset(), WavePreset::Dramatic);
    EXPECT_EQ(widget.waveCount(), 4);
    
    widget.setPreset(WavePreset::Subtle);
    EXPECT_EQ(widget.preset(), WavePreset::Subtle);
    EXPECT_EQ(widget.waveCount(), 2);
    
    widget.setPreset(WavePreset::FlashMessage);
    EXPECT_EQ(widget.preset(), WavePreset::FlashMessage);
    EXPECT_EQ(widget.waveEdge(), WaveEdge::Bottom);
}

TEST_F(WaveWidgetTestFixture, WaveWidgetEdgeConfiguration) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    
    widget.setWaveEdge(WaveEdge::Top);
    EXPECT_EQ(widget.waveEdge(), WaveEdge::Top);
    
    widget.setWaveEdge(WaveEdge::Bottom);
    EXPECT_EQ(widget.waveEdge(), WaveEdge::Bottom);
}

TEST_F(WaveWidgetTestFixture, WaveWidgetColorConfiguration) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    
    QColor fillColor(100, 150, 200, 255);
    widget.setFillColor(fillColor);
    EXPECT_EQ(widget.fillColor(), fillColor);
    
    QColor strokeColor(50, 75, 100, 128);
    widget.setStrokeColor(strokeColor);
    EXPECT_EQ(widget.strokeColor(), strokeColor);
    
    widget.setStrokeWidth(2.5f);
    EXPECT_FLOAT_EQ(widget.strokeWidth(), 2.5f);
}

TEST_F(WaveWidgetTestFixture, WaveWidgetAnimationControl) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    
    EXPECT_FALSE(widget.isPaused());
    
    widget.pause();
    EXPECT_TRUE(widget.isPaused());
    
    widget.resume();
    EXPECT_FALSE(widget.isPaused());
    
    widget.reset();
    EXPECT_FLOAT_EQ(widget.currentTime(), 0.0f);
}

TEST_F(WaveWidgetTestFixture, WaveWidgetViewportSize) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    
    widget.setViewportSize(1920, 1080, 2.0f);
    EXPECT_EQ(widget.viewportWidth(), 1920);
    EXPECT_EQ(widget.viewportHeight(), 1080);
    EXPECT_FLOAT_EQ(widget.devicePixelRatio(), 2.0f);
}

TEST_F(WaveWidgetTestFixture, WaveWidgetCustomWaveParams) {
    int argc = 0;
    char** argv = nullptr;
    if (!initQtApp(argc, argv)) {
        GTEST_SKIP() << "Qt not available";
    }
    
    WaveWidget widget;
    
    WaveParams customParams;
    customParams.amplitude = 15.0f;
    customParams.wavelength = 50.0f;
    customParams.steepness = 0.7f;
    customParams.speed = 2.0f;
    
    widget.setWaveParams(0, customParams);
    WaveParams retrieved = widget.waveParams(0);
    
    EXPECT_FLOAT_EQ(retrieved.amplitude, 15.0f);
    EXPECT_FLOAT_EQ(retrieved.wavelength, 50.0f);
    EXPECT_FLOAT_EQ(retrieved.steepness, 0.7f);
    EXPECT_FLOAT_EQ(retrieved.speed, 2.0f);
}

TEST_F(WaveWidgetTestFixture, WaveParamsDefaultValues) {
    WaveParams params;
    EXPECT_FLOAT_EQ(params.amplitude, 1.0f);
    EXPECT_FLOAT_EQ(params.wavelength, 10.0f);
    EXPECT_FLOAT_EQ(params.steepness, 0.5f);
    EXPECT_FLOAT_EQ(params.speed, 1.0f);
    EXPECT_FLOAT_EQ(params.direction, 0.0f);
    EXPECT_FLOAT_EQ(params.phaseOffset, 0.0f);
}

}

int main(int argc, char **argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
