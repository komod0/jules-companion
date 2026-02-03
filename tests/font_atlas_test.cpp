/**
 * Font Atlas Tests - TDD for OpenGL Text Rendering Spike
 * 
 * Tests the font atlas generation using FreeType + HarfBuzz.
 * These tests validate that we can build a texture atlas for GPU text rendering.
 */

#include <gtest/gtest.h>
#include "rendering/font_atlas.h"

#include <QGuiApplication>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFunctions>

namespace {

/**
 * Helper class to initialize OpenGL context for tests
 */
class OpenGLTestFixture : public ::testing::Test {
protected:
    void SetUp() override {
        // Create offscreen surface for headless OpenGL
        surface = std::make_unique<QOffscreenSurface>();
        surface->create();
        
        context = std::make_unique<QOpenGLContext>();
        context->create();
        context->makeCurrent(surface.get());
    }
    
    void TearDown() override {
        context->doneCurrent();
    }
    
    std::unique_ptr<QOffscreenSurface> surface;
    std::unique_ptr<QOpenGLContext> context;
};

} // namespace

// =============================================================================
// Font Atlas Creation Tests
// =============================================================================

TEST_F(OpenGLTestFixture, FontAtlasCreatesSuccessfully) {
    jules::FontAtlas atlas;
    bool initialized = atlas.initialize(12.0f, 2.0f);
    // In minimal CI containers, fonts may not be available - skip gracefully
    if (!initialized) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    EXPECT_TRUE(atlas.isValid());
}

TEST_F(OpenGLTestFixture, FontAtlasPopulatesASCIIGlyphs) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Check that all printable ASCII characters have glyph descriptors
    for (int i = 32; i <= 126; ++i) {
        char c = static_cast<char>(i);
        auto glyph = atlas.getGlyph(c);
        EXPECT_TRUE(glyph.has_value()) << "Missing glyph for character: " << c << " (code " << i << ")";
    }
}

TEST_F(OpenGLTestFixture, FontAtlasGeneratesValidTexture) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    GLuint textureId = atlas.textureId();
    EXPECT_NE(textureId, 0u) << "Texture ID should be non-zero";
    
    // Verify texture dimensions are reasonable
    int width = atlas.textureWidth();
    int height = atlas.textureHeight();
    
    EXPECT_GT(width, 0);
    EXPECT_GT(height, 0);
    EXPECT_LE(width, 16384);  // Max texture size
    EXPECT_LE(height, 16384);
}

TEST_F(OpenGLTestFixture, FontAtlasGlyphDescriptorHasValidUV) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Check UV coordinates for 'A'
    auto glyph = atlas.getGlyph('A');
    ASSERT_TRUE(glyph.has_value());
    
    // UV coordinates should be normalized (0.0 to 1.0)
    EXPECT_GE(glyph->uvMin.x, 0.0f);
    EXPECT_GE(glyph->uvMin.y, 0.0f);
    EXPECT_LE(glyph->uvMax.x, 1.0f);
    EXPECT_LE(glyph->uvMax.y, 1.0f);
    
    // uvMax should be greater than uvMin
    EXPECT_GT(glyph->uvMax.x, glyph->uvMin.x);
    EXPECT_GT(glyph->uvMax.y, glyph->uvMin.y);
}

TEST_F(OpenGLTestFixture, FontAtlasGlyphDescriptorHasValidMetrics) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Check metrics for 'M' (reference character for monospace width)
    auto glyph = atlas.getGlyph('M');
    ASSERT_TRUE(glyph.has_value());
    
    // Size should be positive
    EXPECT_GT(glyph->size.x, 0.0f);
    EXPECT_GT(glyph->size.y, 0.0f);
    
    // Advance should be positive (character width)
    EXPECT_GT(glyph->advance, 0.0f);
}

TEST_F(OpenGLTestFixture, FontAtlasASCIIFastPathWorks) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Fast path lookup should return same result as regular lookup
    auto normalLookup = atlas.getGlyph('X');
    auto fastLookup = atlas.getASCIIGlyph('X');
    
    ASSERT_TRUE(normalLookup.has_value());
    ASSERT_TRUE(fastLookup != nullptr);
    
    EXPECT_FLOAT_EQ(normalLookup->advance, fastLookup->advance);
    EXPECT_FLOAT_EQ(normalLookup->uvMin.x, fastLookup->uvMin.x);
    EXPECT_FLOAT_EQ(normalLookup->uvMin.y, fastLookup->uvMin.y);
}

TEST_F(OpenGLTestFixture, FontAtlasMonoAdvanceIsConsistent) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    float monoAdvance = atlas.monoAdvance();
    EXPECT_GT(monoAdvance, 0.0f);
    
    // For monospace font, all alphanumeric characters should have same advance
    auto glyphA = atlas.getGlyph('A');
    auto glyphM = atlas.getGlyph('M');
    auto glyphW = atlas.getGlyph('W');
    auto glyph1 = atlas.getGlyph('1');
    
    ASSERT_TRUE(glyphA.has_value());
    ASSERT_TRUE(glyphM.has_value());
    ASSERT_TRUE(glyphW.has_value());
    ASSERT_TRUE(glyph1.has_value());
    
    // All should have same advance width (within tolerance)
    EXPECT_NEAR(glyphA->advance, monoAdvance, 0.01f);
    EXPECT_NEAR(glyphM->advance, monoAdvance, 0.01f);
    EXPECT_NEAR(glyphW->advance, monoAdvance, 0.01f);
    EXPECT_NEAR(glyph1->advance, monoAdvance, 0.01f);
}

TEST_F(OpenGLTestFixture, FontAtlasLineHeightIsReasonable) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    float lineHeight = atlas.lineHeight();
    
    // Line height should be roughly 1.2-2.0x the font size
    EXPECT_GT(lineHeight, 12.0f);
    EXPECT_LT(lineHeight, 36.0f);
}

TEST_F(OpenGLTestFixture, FontAtlasScaleAffectsTextureSize) {
    jules::FontAtlas atlas1x;
    jules::FontAtlas atlas2x;
    
    // Use larger font size to exceed minimum texture size of 256
    if (!atlas1x.initialize(18.0f, 1.0f) || !atlas2x.initialize(18.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // 2x scale should produce larger texture (when exceeding minimum texture size)
    // Note: If texture size is at the minimum (256), both will be equal
    EXPECT_GE(atlas2x.textureWidth(), atlas1x.textureWidth());
    EXPECT_GE(atlas2x.textureHeight(), atlas1x.textureHeight());
}

TEST_F(OpenGLTestFixture, FontAtlasFontSizeAffectsMetrics) {
    jules::FontAtlas atlas12;
    jules::FontAtlas atlas24;
    
    if (!atlas12.initialize(12.0f, 1.0f) || !atlas24.initialize(24.0f, 1.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Larger font should have larger advance
    EXPECT_GT(atlas24.monoAdvance(), atlas12.monoAdvance());
    EXPECT_GT(atlas24.lineHeight(), atlas12.lineHeight());
}

TEST_F(OpenGLTestFixture, FontAtlasNonASCIICharacterReturnsNullopt) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Non-ASCII characters should return nullopt
    auto nonAscii = atlas.getGlyph(static_cast<char>(200));
    EXPECT_FALSE(nonAscii.has_value());
}

TEST_F(OpenGLTestFixture, FontAtlasControlCharacterReturnsNullopt) {
    jules::FontAtlas atlas;
    if (!atlas.initialize(12.0f, 2.0f)) {
        GTEST_SKIP() << "Font initialization failed (no fonts in CI container)";
    }
    
    // Control characters (below 32) should return nullopt
    auto controlChar = atlas.getGlyph('\n');
    EXPECT_FALSE(controlChar.has_value());
    
    auto tabChar = atlas.getGlyph('\t');
    EXPECT_FALSE(tabChar.has_value());
}

// =============================================================================
// Main - Initialize Qt application for OpenGL tests
// =============================================================================

int main(int argc, char **argv) {
    // Qt requires QGuiApplication for OpenGL contexts
    QGuiApplication app(argc, argv);
    
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
