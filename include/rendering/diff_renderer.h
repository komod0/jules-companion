#pragma once

#include <QOpenGLFunctions_3_3_Core>
#include <QOpenGLShaderProgram>
#include <QOpenGLBuffer>
#include <QOpenGLVertexArrayObject>

#include <memory>
#include <vector>
#include <string>
#include <unordered_map>
#include <optional>
#include <cstddef>
#include "data/settings_manager.h"

namespace jules {

enum class DiffLineType {
    Context,
    Added,
    Removed,
    FileHeader,
    HunkHeader
};

struct RGBA {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
    float a = 1.0f;
};

struct SyntaxColorToken {
    std::size_t start = 0;
    std::size_t end = 0;
    RGBA color;
};

struct DiffLineInfo {
    int lineIndex = 0;
    int sectionIndex = 0;
    DiffLineType type = DiffLineType::Context;
    std::string content;
    std::optional<int> oldLineNumber;
    std::optional<int> newLineNumber;
    RGBA backgroundColor;
    std::vector<SyntaxColorToken> syntaxTokens;
    std::vector<std::pair<std::size_t, std::size_t>> tokenChanges;
};

struct DiffSection {
    std::string patch;
    std::string language;
    std::string filename;
};

struct TextPosition {
    int line = 0;
    int column = 0;
};

struct TextSelection {
    TextPosition start;
    TextPosition end;
};

struct ViewportSize {
    int width = 0;
    int height = 0;
    float devicePixelRatio = 1.0f;
};

struct DiffInstanceData {
    float originX = 0.0f;
    float originY = 0.0f;
    float sizeX = 0.0f;
    float sizeY = 0.0f;
    float uvMinX = 0.0f;
    float uvMinY = 0.0f;
    float uvMaxX = 0.0f;
    float uvMaxY = 0.0f;
    float colorR = 0.0f;
    float colorG = 0.0f;
    float colorB = 0.0f;
    float colorA = 1.0f;
};

struct DiffRectInstance {
    float originX = 0.0f;
    float originY = 0.0f;
    float sizeX = 0.0f;
    float sizeY = 0.0f;
    float colorR = 0.0f;
    float colorG = 0.0f;
    float colorB = 0.0f;
    float colorA = 1.0f;
    float cornerRadius = 0.0f;
    float borderWidth = 0.0f;
    float borderColorR = 0.0f;
    float borderColorG = 0.0f;
    float borderColorB = 0.0f;
    float borderColorA = 0.0f;
    float padding1 = 0.0f;
    float padding2 = 0.0f;
};

struct RenderResult {
    std::vector<DiffInstanceData> textInstances;
    std::vector<DiffInstanceData> boldInstances;
    std::vector<DiffRectInstance> rectInstances;
    bool cacheHit = false;
};

struct DiffLine {
    std::string content;
    DiffLineType type = DiffLineType::Context;
    std::optional<int> oldLineNumber;
    std::optional<int> newLineNumber;
    std::vector<std::pair<std::size_t, std::size_t>> tokenChanges;
};

struct ParsedDiffSection {
    std::string filename;
    std::string language;
    std::vector<DiffLine> lines;
    int linesAdded = 0;
    int linesRemoved = 0;
    bool isNewFile = false;
    bool isBinary = false;
    float yOffset = 0.0f;
    float height = 0.0f;
    float maxContentWidth = 0.0f;
};

struct TileLayout {
    int id = 0;
    int startLine = 0;
    int endLine = 0;
    float yOffset = 0.0f;
    float height = 0.0f;
};

class SharedSyntaxCache;

class DiffRenderer {
public:
    DiffRenderer();
    ~DiffRenderer();

    DiffRenderer(const DiffRenderer&) = delete;
    DiffRenderer& operator=(const DiffRenderer&) = delete;
    DiffRenderer(DiffRenderer&&) noexcept;
    DiffRenderer& operator=(DiffRenderer&&) noexcept;

    bool initialize();
    bool isInitialized() const;

    void setSharedSyntaxCache(SharedSyntaxCache* cache);
    
    void setViewportSize(int width, int height, float devicePixelRatio);
    ViewportSize viewportSize() const;
    
    float monoAdvance() const;
    float lineHeight() const;
    
    void setDiffSections(const std::vector<DiffSection>& sections);
    int sectionCount() const;
    float totalContentHeight() const;
    
    std::vector<DiffLineInfo> visibleLines(float viewportTop, float viewportBottom) const;
    
    RenderResult generateRenderData(float viewportTop, float viewportBottom);
    
    void setHorizontalScroll(int sectionIndex, float offset);
    float horizontalScroll(int sectionIndex) const;
    float maxHorizontalScroll(int sectionIndex) const;
    
    void setSelection(const TextPosition& start, const TextPosition& end);
    void clearSelection();
    void selectAll();
    TextSelection selection() const;
    std::string selectedText() const;

    int sectionIndexAtY(float worldY) const;
    std::string sectionFilename(int sectionIndex) const;
    
    bool isSyntaxHighlightingSupported() const;
    bool isSyntaxHighlightingInProgress() const;

    void setTheme(Theme theme);

    void invalidateCache();
    
    static constexpr float kHeaderHeight = 35.0f;
    static constexpr float kFooterHeight = 8.0f;
    static constexpr float kSectionSpacing = 32.0f;
    static constexpr float kGutterWidth = 80.0f;
    static constexpr float kHorizontalPadding = 24.0f;
    
private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace jules
