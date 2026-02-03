/**
 * Diff Renderer Tests - TDD for Full Diff Renderer with Syntax Highlighting
 * 
 * Tests the diff renderer which provides:
 * - Line-by-line rendering with add/remove/context colors
 * - Tree-sitter syntax highlighting integration
 * - Tile-based virtualization for large diffs (100,000+ lines)
 * - Smooth scrolling at 60fps
 * 
 * Port of Mac's UnifiedMetalDiffView.swift and related components.
 */

#include <gtest/gtest.h>
#include "rendering/diff_renderer.h"

#include <QGuiApplication>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QElapsedTimer>

#include <chrono>
#include <sstream>
#include <random>

namespace {

/**
 * Helper class to initialize OpenGL context for tests
 */
class DiffRendererTestFixture : public ::testing::Test {
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
    
    // Helper to generate a diff patch string
    static std::string generatePatch(int addedLines, int removedLines, int contextLines) {
        std::ostringstream ss;
        ss << "diff --git a/file.cpp b/file.cpp\n";
        ss << "--- a/file.cpp\n";
        ss << "+++ b/file.cpp\n";
        ss << "@@ -1," << (removedLines + contextLines) << " +1," << (addedLines + contextLines) << " @@\n";
        
        // Context lines
        for (int i = 0; i < contextLines; ++i) {
            ss << " // Context line " << i << "\n";
        }
        
        // Removed lines
        for (int i = 0; i < removedLines; ++i) {
            ss << "-// Removed line " << i << "\n";
        }
        
        // Added lines
        for (int i = 0; i < addedLines; ++i) {
            ss << "+// Added line " << i << "\n";
        }
        
        return ss.str();
    }
    
    // Helper to generate a large diff
    static std::string generateLargeDiff(int totalLines) {
        std::ostringstream ss;
        ss << "diff --git a/large_file.cpp b/large_file.cpp\n";
        ss << "--- a/large_file.cpp\n";
        ss << "+++ b/large_file.cpp\n";
        ss << "@@ -1," << totalLines << " +1," << totalLines << " @@\n";
        
        std::mt19937 rng(42);  // Fixed seed for reproducibility
        std::uniform_int_distribution<int> dist(0, 2);
        
        for (int i = 0; i < totalLines; ++i) {
            int type = dist(rng);
            if (type == 0) {
                ss << " // Context line " << i << ": void foo() { return x + y; }\n";
            } else if (type == 1) {
                ss << "+// Added line " << i << ": int x = calculateValue(a, b, c);\n";
            } else {
                ss << "-// Removed line " << i << ": int y = oldCalculation(a, b);\n";
            }
        }
        
        return ss.str();
    }
};

} // namespace

// =============================================================================
// DiffRenderer Initialization Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, DiffRendererCreatesSuccessfully) {
    jules::DiffRenderer renderer;
    bool initialized = renderer.initialize();
    // In minimal CI containers, fonts may not be available - skip gracefully
    if (!initialized) {
        GTEST_SKIP() << "DiffRenderer initialization failed (no fonts in CI container)";
    }
    EXPECT_TRUE(renderer.isInitialized());
}

TEST_F(DiffRendererTestFixture, DiffRendererSetsViewportSize) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    renderer.setViewportSize(1920, 1080, 2.0f);
    
    auto viewport = renderer.viewportSize();
    EXPECT_EQ(viewport.width, 1920);
    EXPECT_EQ(viewport.height, 1080);
    EXPECT_FLOAT_EQ(viewport.devicePixelRatio, 2.0f);
}

TEST_F(DiffRendererTestFixture, DiffRendererHasValidFontAtlas) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    EXPECT_GT(renderer.monoAdvance(), 0.0f);
    EXPECT_GT(renderer.lineHeight(), 0.0f);
}

// =============================================================================
// Diff Content Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, DiffRendererSetsDiffContent) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = generatePatch(10, 5, 3);
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "test.cpp";
    
    renderer.setDiffSections({section});
    
    EXPECT_EQ(renderer.sectionCount(), 1);
    EXPECT_GT(renderer.totalContentHeight(), 0.0f);
}

TEST_F(DiffRendererTestFixture, DiffRendererMultipleSections) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::vector<jules::DiffSection> sections;
    for (int i = 0; i < 5; ++i) {
        jules::DiffSection section;
        section.patch = generatePatch(10 + i * 5, 5 + i * 2, 3);
        section.language = "cpp";
        section.filename = "file" + std::to_string(i) + ".cpp";
        sections.push_back(section);
    }
    
    renderer.setDiffSections(sections);
    
    EXPECT_EQ(renderer.sectionCount(), 5);
}

// =============================================================================
// Line Type Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, DiffRendererIdentifiesLineTypes) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = R"(diff --git a/file.cpp b/file.cpp
--- a/file.cpp
+++ b/file.cpp
@@ -1,5 +1,6 @@
 int main() {
-    int x = 1;
+    int x = 2;
+    int y = 3;
     return 0;
 }
)";
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "file.cpp";
    
    renderer.setDiffSections({section});
    
    auto lines = renderer.visibleLines(0, 1000);
    ASSERT_GT(lines.size(), 0);
    
    // Should have context, added, removed lines
    bool hasContext = false;
    bool hasAdded = false;
    bool hasRemoved = false;
    
    for (const auto& line : lines) {
        if (line.type == jules::DiffLineType::Context) hasContext = true;
        if (line.type == jules::DiffLineType::Added) hasAdded = true;
        if (line.type == jules::DiffLineType::Removed) hasRemoved = true;
    }
    
    EXPECT_TRUE(hasContext);
    EXPECT_TRUE(hasAdded);
    EXPECT_TRUE(hasRemoved);
}

// =============================================================================
// Color Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, AddedLinesHaveGreenBackground) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = generatePatch(5, 0, 2);
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "test.cpp";
    
    renderer.setDiffSections({section});
    
    auto lines = renderer.visibleLines(0, 1000);
    
    for (const auto& line : lines) {
        if (line.type == jules::DiffLineType::Added) {
            // Green-ish background (RGB values where G is dominant)
            EXPECT_GT(line.backgroundColor.g, line.backgroundColor.r);
            EXPECT_GT(line.backgroundColor.g, 0.0f);
        }
    }
}

TEST_F(DiffRendererTestFixture, RemovedLinesHaveRedBackground) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = generatePatch(0, 5, 2);
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "test.cpp";
    
    renderer.setDiffSections({section});
    
    auto lines = renderer.visibleLines(0, 1000);
    
    for (const auto& line : lines) {
        if (line.type == jules::DiffLineType::Removed) {
            // Red-ish background (RGB values where R is dominant)
            EXPECT_GT(line.backgroundColor.r, line.backgroundColor.g);
            EXPECT_GT(line.backgroundColor.r, 0.0f);
        }
    }
}

// =============================================================================
// Syntax Highlighting Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, SyntaxHighlightingAppliesToLines) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = R"(diff --git a/config.json b/config.json
--- a/config.json
+++ b/config.json
@@ -1,3 +1,4 @@
 {
+    "name": "test",
     "value": 42
 }
)";
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "json";
    section.filename = "config.json";
    
    renderer.setDiffSections({section});
    
    // Request generation of instances (triggers syntax highlighting)
    renderer.setViewportSize(800, 600, 1.0f);
    renderer.generateRenderData(0.0f, 600.0f);
    
    // Check that lines have syntax tokens
    auto lines = renderer.visibleLines(0, 600);
    
    bool hasSyntaxColoring = false;
    for (const auto& line : lines) {
        if (!line.syntaxTokens.empty()) {
            hasSyntaxColoring = true;
            break;
        }
    }
    
    // Note: This may fail if tree-sitter grammars aren't available
    // which is acceptable in CI environments
    if (renderer.syntaxHighlightingAvailable()) {
        EXPECT_TRUE(hasSyntaxColoring) << "Expected syntax tokens when highlighting is available";
    }
}

// =============================================================================
// Tile-Based Virtualization Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, TileVirtualizationHandlesLargeDiff) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    // Generate a 10,000 line diff
    std::string largePatch = generateLargeDiff(10000);
    
    jules::DiffSection section;
    section.patch = largePatch;
    section.language = "cpp";
    section.filename = "large_file.cpp";
    
    renderer.setDiffSections({section});
    
    EXPECT_EQ(renderer.sectionCount(), 1);
    EXPECT_GT(renderer.totalContentHeight(), 10000 * renderer.lineHeight() * 0.9f);
}

TEST_F(DiffRendererTestFixture, OnlyVisibleTilesAreRendered) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string largePatch = generateLargeDiff(10000);
    
    jules::DiffSection section;
    section.patch = largePatch;
    section.language = "cpp";
    section.filename = "large_file.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(1920, 1080, 1.0f);
    
    // Get visible lines for viewport at top
    auto topLines = renderer.visibleLines(0, 1080);
    EXPECT_LT(topLines.size(), 1000) << "Should only render visible lines, not all 10000";
    
    // Get visible lines for viewport at middle
    float middleY = renderer.totalContentHeight() / 2.0f;
    auto middleLines = renderer.visibleLines(middleY, middleY + 1080);
    EXPECT_LT(middleLines.size(), 1000) << "Should only render visible lines";
    
    // Both should have similar count (viewport-limited)
    EXPECT_NEAR(static_cast<float>(topLines.size()), 
                static_cast<float>(middleLines.size()), 
                100.0f);
}

TEST_F(DiffRendererTestFixture, ScrollingUpdatesVisibleRange) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string largePatch = generateLargeDiff(1000);
    
    jules::DiffSection section;
    section.patch = largePatch;
    section.language = "cpp";
    section.filename = "large_file.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(800, 600, 1.0f);
    
    auto linesAt0 = renderer.visibleLines(0, 600);
    auto linesAt500 = renderer.visibleLines(500 * renderer.lineHeight(), 
                                             (500 + 40) * renderer.lineHeight());
    
    ASSERT_GT(linesAt0.size(), 0);
    ASSERT_GT(linesAt500.size(), 0);
    
    // First visible line should be different
    EXPECT_NE(linesAt0[0].lineIndex, linesAt500[0].lineIndex);
}

// =============================================================================
// Performance Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, LargeDiffLoadsWithoutLag) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    QElapsedTimer timer;
    timer.start();
    
    // Generate and load 10,000 line diff
    std::string largePatch = generateLargeDiff(10000);
    
    jules::DiffSection section;
    section.patch = largePatch;
    section.language = "cpp";
    section.filename = "large_file.cpp";
    
    renderer.setDiffSections({section});
    
    qint64 loadTime = timer.elapsed();
    
    // Should load in under 2 seconds
    EXPECT_LT(loadTime, 2000) << "10,000 line diff took " << loadTime << "ms to load";
}

TEST_F(DiffRendererTestFixture, RenderingMaintains60FPS) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string largePatch = generateLargeDiff(10000);
    
    jules::DiffSection section;
    section.patch = largePatch;
    section.language = "cpp";
    section.filename = "large_file.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(1920, 1080, 1.0f);
    
    // Simulate scrolling and measure frame times
    const int numFrames = 60;
    std::vector<double> frameTimes;
    frameTimes.reserve(numFrames);
    
    float scrollY = 0.0f;
    float scrollStep = renderer.totalContentHeight() / static_cast<float>(numFrames);
    
    for (int i = 0; i < numFrames; ++i) {
        auto start = std::chrono::high_resolution_clock::now();
        
        auto renderData = renderer.generateRenderData(scrollY, scrollY + 1080.0f);
        
        auto end = std::chrono::high_resolution_clock::now();
        double frameMs = std::chrono::duration<double, std::milli>(end - start).count();
        frameTimes.push_back(frameMs);
        
        scrollY += scrollStep;
    }
    
    // Calculate average and 95th percentile
    double sum = 0.0;
    for (double t : frameTimes) sum += t;
    double avg = sum / frameTimes.size();
    
    std::sort(frameTimes.begin(), frameTimes.end());
    double p95 = frameTimes[static_cast<size_t>(frameTimes.size() * 0.95)];
    
    // For 60fps, we need <16.67ms per frame
    // Allow some overhead for test environment
    EXPECT_LT(avg, 16.67) << "Average frame time: " << avg << "ms";
    EXPECT_LT(p95, 25.0) << "95th percentile frame time: " << p95 << "ms";
}

// =============================================================================
// 100,000 Line Stress Test
// =============================================================================

TEST_F(DiffRendererTestFixture, Handles100KLineDiff) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    QElapsedTimer timer;
    timer.start();
    
    // Generate 100,000 line diff
    std::string hugePatch = generateLargeDiff(100000);
    
    jules::DiffSection section;
    section.patch = hugePatch;
    section.language = "cpp";
    section.filename = "huge_file.cpp";
    
    renderer.setDiffSections({section});
    
    qint64 loadTime = timer.elapsed();
    
    // Should load in under 10 seconds (allowing for parsing overhead)
    EXPECT_LT(loadTime, 10000) << "100,000 line diff took " << loadTime << "ms to load";
    
    // Verify it rendered
    EXPECT_EQ(renderer.sectionCount(), 1);
    
    renderer.setViewportSize(1920, 1080, 1.0f);
    
    // Should still be fast to get visible lines
    timer.restart();
    auto visibleLines = renderer.visibleLines(50000 * renderer.lineHeight(), 
                                               (50000 + 100) * renderer.lineHeight());
    qint64 visibleTime = timer.elapsed();
    
    EXPECT_LT(visibleTime, 50) << "Getting visible lines took " << visibleTime << "ms";
    EXPECT_GT(visibleLines.size(), 0);
}

// =============================================================================
// Scrolling Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, SmoothScrollingWorks) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = generateLargeDiff(1000);
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "file.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(800, 600, 1.0f);
    
    // Scroll should work at sub-line increments
    float lineHeight = renderer.lineHeight();
    
    auto lines1 = renderer.visibleLines(0, 600);
    auto lines2 = renderer.visibleLines(lineHeight * 0.5f, 600 + lineHeight * 0.5f);
    
    EXPECT_GT(lines1.size(), 0);
    EXPECT_GT(lines2.size(), 0);
    
    // Both should have roughly the same visible lines (slight scroll)
    EXPECT_NEAR(static_cast<float>(lines1.size()), 
                static_cast<float>(lines2.size()), 
                2.0f);
}

TEST_F(DiffRendererTestFixture, HorizontalScrollPerSection) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    // Create two sections
    std::vector<jules::DiffSection> sections;
    
    jules::DiffSection section1;
    section1.patch = generatePatch(10, 5, 3);
    section1.language = "cpp";
    section1.filename = "file1.cpp";
    sections.push_back(section1);
    
    jules::DiffSection section2;
    section2.patch = generatePatch(15, 8, 5);
    section2.language = "cpp";
    section2.filename = "file2.cpp";
    sections.push_back(section2);
    
    renderer.setDiffSections(sections);
    renderer.setViewportSize(800, 600, 1.0f);
    
    // Set different horizontal scroll for each section
    renderer.setHorizontalScroll(0, 100.0f);
    renderer.setHorizontalScroll(1, 200.0f);
    
    EXPECT_FLOAT_EQ(renderer.horizontalScroll(0), 100.0f);
    EXPECT_FLOAT_EQ(renderer.horizontalScroll(1), 200.0f);
}

// =============================================================================
// Selection Tests (Basic)
// =============================================================================

TEST_F(DiffRendererTestFixture, SelectionWorks) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = generatePatch(10, 5, 3);
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "test.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(800, 600, 1.0f);
    
    // Set selection
    jules::TextPosition start{2, 5};
    jules::TextPosition end{4, 10};
    renderer.setSelection(start, end);
    
    auto selection = renderer.selection();
    EXPECT_EQ(selection.start.line, 2);
    EXPECT_EQ(selection.start.column, 5);
    EXPECT_EQ(selection.end.line, 4);
    EXPECT_EQ(selection.end.column, 10);
}

TEST_F(DiffRendererTestFixture, CopySelectedText) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = R"(diff --git a/file.cpp b/file.cpp
--- a/file.cpp
+++ b/file.cpp
@@ -1,3 +1,3 @@
 int main() {
-    return 0;
+    return 1;
 }
)";
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "file.cpp";
    
    renderer.setDiffSections({section});
    
    // Select "int main()"
    jules::TextPosition start{0, 0};
    jules::TextPosition end{0, 10};
    renderer.setSelection(start, end);
    
    std::string selectedText = renderer.selectedText();
    EXPECT_FALSE(selectedText.empty());
}

// =============================================================================
// Cache Tests
// =============================================================================

TEST_F(DiffRendererTestFixture, RenderCacheWorks) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch = generateLargeDiff(1000);
    
    jules::DiffSection section;
    section.patch = patch;
    section.language = "cpp";
    section.filename = "file.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(800, 600, 1.0f);
    
    // First render (cache miss)
    auto result1 = renderer.generateRenderData(0, 600);
    EXPECT_FALSE(result1.cacheHit);
    
    // Same viewport (cache hit)
    auto result2 = renderer.generateRenderData(0, 600);
    EXPECT_TRUE(result2.cacheHit);
    
    // Different viewport (cache miss)
    auto result3 = renderer.generateRenderData(1000, 1600);
    EXPECT_FALSE(result3.cacheHit);
}

TEST_F(DiffRendererTestFixture, CacheInvalidatesOnContentChange) {
    jules::DiffRenderer renderer;
    ASSERT_TRUE(renderer.initialize());
    
    std::string patch1 = generatePatch(10, 5, 3);
    
    jules::DiffSection section;
    section.patch = patch1;
    section.language = "cpp";
    section.filename = "file.cpp";
    
    renderer.setDiffSections({section});
    renderer.setViewportSize(800, 600, 1.0f);
    
    auto result1 = renderer.generateRenderData(0, 600);
    EXPECT_FALSE(result1.cacheHit);
    
    // Change content
    std::string patch2 = generatePatch(20, 10, 5);
    section.patch = patch2;
    renderer.setDiffSections({section});
    
    // Should be cache miss after content change
    auto result2 = renderer.generateRenderData(0, 600);
    EXPECT_FALSE(result2.cacheHit);
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
