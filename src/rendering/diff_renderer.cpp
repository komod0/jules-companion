#include "rendering/diff_renderer.h"
#include "rendering/font_atlas.h"
#include "highlighting/syntax_highlighter.h"

#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QDebug>

#include <algorithm>
#include <cmath>
#include <sstream>
#include <regex>
#include <mutex>
#include <future>

namespace jules {

namespace {

struct DiffColors {
    RGBA addedBg{0.161f, 0.251f, 0.165f, 1.0f};
    RGBA removedBg{0.314f, 0.161f, 0.165f, 1.0f};
    RGBA contextBg{0.0f, 0.0f, 0.0f, 0.0f};
    RGBA headerBg{0.118f, 0.118f, 0.118f, 1.0f};
    RGBA textDefault{0.9f, 0.9f, 0.9f, 1.0f};
    RGBA gutterText{0.5f, 0.5f, 0.5f, 1.0f};
    RGBA gutterBg{0.08f, 0.08f, 0.08f, 1.0f};
    RGBA sectionBorder{0.25f, 0.25f, 0.25f, 1.0f};
    RGBA selectionBg{0.3f, 0.4f, 0.6f, 0.5f};
    RGBA highlightBg{0.4f, 0.4f, 0.2f, 0.5f};
};

struct LocalDiffLine {
    std::string content;
    DiffLineType type = DiffLineType::Context;
    std::optional<int> oldLineNumber;
    std::optional<int> newLineNumber;
    std::vector<std::pair<std::size_t, std::size_t>> tokenChanges;
};

struct ParsedPatchResult {
    std::vector<LocalDiffLine> lines;
    std::string language;
    int linesAdded = 0;
    int linesRemoved = 0;
    std::string filename;
};

ParsedPatchResult parsePatch(const std::string& patch, const std::string& language,
                             const std::string& filename) {
    ParsedPatchResult result;
    result.language = language;
    
    std::istringstream stream(patch);
    std::string line;
    
    int oldLineNum = 0;
    int newLineNum = 0;
    bool inHunk = false;
    
    std::regex hunkHeaderRegex(R"(@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@.*)");
    
    while (std::getline(stream, line)) {
        if (line.empty()) continue;
        
        if (line.rfind("diff --git", 0) == 0 || 
            line.rfind("index ", 0) == 0 ||
            line.rfind("--- ", 0) == 0 ||
            line.rfind("+++ ", 0) == 0) {
            continue;
        }
        
        std::smatch match;
        if (std::regex_match(line, match, hunkHeaderRegex)) {
            oldLineNum = std::stoi(match[1].str());
            newLineNum = std::stoi(match[2].str());
            inHunk = true;
            
            LocalDiffLine hunkLine;
            hunkLine.content = line;
            hunkLine.type = DiffLineType::HunkHeader;
            result.lines.push_back(hunkLine);
            continue;
        }
        
        if (!inHunk) continue;
        
        LocalDiffLine diffLine;
        
        if (!line.empty()) {
            char prefix = line[0];
            std::string content = line.length() > 1 ? line.substr(1) : "";
            
            switch (prefix) {
                case '+':
                    diffLine.type = DiffLineType::Added;
                    diffLine.content = content;
                    diffLine.newLineNumber = newLineNum++;
                    break;
                case '-':
                    diffLine.type = DiffLineType::Removed;
                    diffLine.content = content;
                    diffLine.oldLineNumber = oldLineNum++;
                    break;
                case ' ':
                default:
                    diffLine.type = DiffLineType::Context;
                    diffLine.content = content;
                    diffLine.oldLineNumber = oldLineNum++;
                    diffLine.newLineNumber = newLineNum++;
                    break;
            }
        }
        
        result.lines.push_back(diffLine);
    }
    
    return result;
}

}  // namespace

class DiffRenderer::Impl {
public:
    Impl() = default;
    ~Impl() = default;
    
    bool initialize() {
        auto* ctx = QOpenGLContext::currentContext();
        if (!ctx) {
            qWarning() << "DiffRenderer: No OpenGL context";
            return false;
        }
        
        m_gl = ctx->functions();
        if (!m_gl) {
            qWarning() << "DiffRenderer: Failed to get OpenGL functions";
            return false;
        }
        
        m_fontAtlas = std::make_unique<FontAtlas>();
        if (!m_fontAtlas->initialize(12.0f, m_devicePixelRatio)) {
            qWarning() << "DiffRenderer: Failed to initialize font atlas";
            return false;
        }
        
        m_lineHeight = m_fontAtlas->lineHeight();
        m_monoAdvance = m_fontAtlas->monoAdvance();
        
        m_syntaxHighlighter = std::make_unique<highlighting::SyntaxHighlighter>();
        
        m_initialized = true;
        return true;
    }
    
    bool isInitialized() const { return m_initialized; }
    
    void setViewportSize(int width, int height, float dpr) {
        m_viewportWidth = width;
        m_viewportHeight = height;
        m_devicePixelRatio = dpr;
        
        if (m_fontAtlas) {
            m_fontAtlas->updateScale(dpr);
            m_lineHeight = m_fontAtlas->lineHeight();
            m_monoAdvance = m_fontAtlas->monoAdvance();
        }
        
        invalidateCache();
    }
    
    ViewportSize viewportSize() const {
        return {m_viewportWidth, m_viewportHeight, m_devicePixelRatio};
    }
    
    float monoAdvance() const { return m_monoAdvance; }
    float lineHeight() const { return m_lineHeight; }
    
    void setDiffSections(const std::vector<DiffSection>& sections) {
        m_sections.clear();
        m_globalLines.clear();
        m_totalHeight = 0.0f;
        m_syntaxColorCache.clear();
        m_horizontalScrolls.clear();
        
        float currentY = DiffRenderer::kSectionSpacing;
        int globalLineIndex = 0;
        
        for (size_t sectionIdx = 0; sectionIdx < sections.size(); ++sectionIdx) {
            const auto& section = sections[sectionIdx];
            
            auto parseResult = parsePatch(section.patch, section.language, section.filename);
            
            ParsedDiffSection parsedSection;
            parsedSection.filename = section.filename;
            parsedSection.language = section.language;
            parsedSection.yOffset = currentY;
            
            float maxLineWidth = 0.0f;
            
            for (const auto& line : parseResult.lines) {
                DiffLine diffLine;
                diffLine.content = line.content;
                diffLine.type = line.type;
                diffLine.oldLineNumber = line.oldLineNumber;
                diffLine.newLineNumber = line.newLineNumber;
                diffLine.tokenChanges = line.tokenChanges;
                parsedSection.lines.push_back(diffLine);
                
                if (line.type == DiffLineType::Added) {
                    parsedSection.linesAdded++;
                } else if (line.type == DiffLineType::Removed) {
                    parsedSection.linesRemoved++;
                }
                
                float lineWidth = static_cast<float>(line.content.length()) * m_monoAdvance;
                maxLineWidth = std::max(maxLineWidth, lineWidth);
                
                GlobalLineInfo globalLine;
                globalLine.globalIndex = globalLineIndex++;
                globalLine.sectionIndex = static_cast<int>(sectionIdx);
                globalLine.localIndex = static_cast<int>(m_globalLines.size() - 
                    (sectionIdx > 0 ? m_sections[sectionIdx - 1].lines.size() : 0));
                globalLine.yOffset = currentY + DiffRenderer::kHeaderHeight + 
                    static_cast<float>(parsedSection.lines.size() - 1) * m_lineHeight;
                    
                m_globalLines.push_back(globalLine);
            }
            
            parsedSection.maxContentWidth = maxLineWidth;
            float contentHeight = static_cast<float>(parsedSection.lines.size()) * m_lineHeight;
            parsedSection.height = DiffRenderer::kHeaderHeight + contentHeight + DiffRenderer::kFooterHeight;
            
            m_sections.push_back(parsedSection);
            
            currentY += parsedSection.height + DiffRenderer::kSectionSpacing;
        }
        
        m_totalHeight = currentY;
        rebuildLineManager();
        
        parseSyntaxAsync();
        
        invalidateCache();
    }
    
    int sectionCount() const {
        return static_cast<int>(m_sections.size());
    }
    
    float totalContentHeight() const {
        return m_totalHeight;
    }
    
    std::vector<DiffLineInfo> visibleLines(float viewportTop, float viewportBottom) const {
        std::vector<DiffLineInfo> result;
        
        int firstLine = static_cast<int>(std::max(0.0f, viewportTop / m_lineHeight - 10));
        int lastLine = static_cast<int>((viewportBottom / m_lineHeight) + 10);
        
        int currentLine = 0;
        for (size_t sectionIdx = 0; sectionIdx < m_sections.size(); ++sectionIdx) {
            const auto& section = m_sections[sectionIdx];
            
            float sectionTop = section.yOffset;
            float sectionBottom = section.yOffset + section.height;
            
            if (sectionBottom < viewportTop) {
                currentLine += static_cast<int>(section.lines.size());
                continue;
            }
            if (sectionTop > viewportBottom) {
                break;
            }
            
            for (size_t lineIdx = 0; lineIdx < section.lines.size(); ++lineIdx) {
                const auto& line = section.lines[lineIdx];
                
                float lineY = section.yOffset + DiffRenderer::kHeaderHeight + 
                    static_cast<float>(lineIdx) * m_lineHeight;
                
                if (lineY + m_lineHeight < viewportTop) {
                    currentLine++;
                    continue;
                }
                if (lineY > viewportBottom) {
                    break;
                }
                
                DiffLineInfo info;
                info.lineIndex = currentLine;
                info.sectionIndex = static_cast<int>(sectionIdx);
                info.type = line.type;
                info.content = line.content;
                info.oldLineNumber = line.oldLineNumber;
                info.newLineNumber = line.newLineNumber;
                
                switch (line.type) {
                    case DiffLineType::Added:
                        info.backgroundColor = m_colors.addedBg;
                        break;
                    case DiffLineType::Removed:
                        info.backgroundColor = m_colors.removedBg;
                        break;
                    default:
                        info.backgroundColor = m_colors.contextBg;
                        break;
                }
                
                auto cacheIt = m_syntaxColorCache.find(currentLine);
                if (cacheIt != m_syntaxColorCache.end()) {
                    info.syntaxTokens = cacheIt->second;
                }
                
                info.tokenChanges.insert(info.tokenChanges.end(),
                    line.tokenChanges.begin(), line.tokenChanges.end());
                
                result.push_back(info);
                currentLine++;
            }
        }
        
        return result;
    }
    
    RenderResult generateRenderData(float viewportTop, float viewportBottom) {
        RenderResult result;
        
        if (m_cachedViewportTop == viewportTop && 
            m_cachedViewportBottom == viewportBottom &&
            !m_cacheInvalid) {
            result.textInstances = m_cachedTextInstances;
            result.boldInstances = m_cachedBoldInstances;
            result.rectInstances = m_cachedRectInstances;
            result.cacheHit = true;
            return result;
        }
        
        m_cachedTextInstances.clear();
        m_cachedBoldInstances.clear();
        m_cachedRectInstances.clear();
        
        generateBackgrounds(viewportTop, viewportBottom);
        generateText(viewportTop, viewportBottom);
        
        result.textInstances = m_cachedTextInstances;
        result.boldInstances = m_cachedBoldInstances;
        result.rectInstances = m_cachedRectInstances;
        result.cacheHit = false;
        
        m_cachedViewportTop = viewportTop;
        m_cachedViewportBottom = viewportBottom;
        m_cacheInvalid = false;
        
        return result;
    }
    
    void setHorizontalScroll(int sectionIndex, float offset) {
        m_horizontalScrolls[sectionIndex] = std::max(0.0f, offset);
        invalidateCache();
    }
    
    float horizontalScroll(int sectionIndex) const {
        auto it = m_horizontalScrolls.find(sectionIndex);
        return it != m_horizontalScrolls.end() ? it->second : 0.0f;
    }
    
    float maxHorizontalScroll(int sectionIndex) const {
        if (sectionIndex < 0 || sectionIndex >= static_cast<int>(m_sections.size())) {
            return 0.0f;
        }
        
        const auto& section = m_sections[sectionIndex];
        float contentWidth = DiffRenderer::kHorizontalPadding + DiffRenderer::kGutterWidth +
            10.0f + section.maxContentWidth + 100.0f;
        return std::max(0.0f, contentWidth - static_cast<float>(m_viewportWidth));
    }
    
    void setSelection(const TextPosition& start, const TextPosition& end) {
        m_selectionStart = start;
        m_selectionEnd = end;
        m_hasSelection = true;
        invalidateCache();
    }
    
    void clearSelection() {
        m_hasSelection = false;
        invalidateCache();
    }
    
    TextSelection selection() const {
        TextSelection sel;
        sel.start = m_selectionStart;
        sel.end = m_selectionEnd;
        return sel;
    }
    
    std::string selectedText() const {
        if (!m_hasSelection) return "";
        
        int startLine = m_selectionStart.line;
        int startCol = m_selectionStart.column;
        int endLine = m_selectionEnd.line;
        int endCol = m_selectionEnd.column;
        
        if (startLine > endLine || (startLine == endLine && startCol > endCol)) {
            std::swap(startLine, endLine);
            std::swap(startCol, endCol);
        }
        
        std::string result;
        int currentLine = 0;
        
        for (const auto& section : m_sections) {
            for (const auto& line : section.lines) {
                if (currentLine >= startLine && currentLine <= endLine) {
                    const std::string& lineContent = line.content;
                    int lineLen = static_cast<int>(lineContent.length());
                    
                    if (currentLine == startLine && currentLine == endLine) {
                        int start = std::min(startCol, lineLen);
                        int end = std::min(endCol, lineLen);
                        if (end > start) {
                            result += lineContent.substr(start, end - start);
                        }
                    } else if (currentLine == startLine) {
                        int start = std::min(startCol, lineLen);
                        result += lineContent.substr(start) + "\n";
                    } else if (currentLine == endLine) {
                        int end = std::min(endCol, lineLen);
                        result += lineContent.substr(0, end);
                    } else {
                        result += lineContent + "\n";
                    }
                }
                currentLine++;
            }
        }
        
        return result;
    }
    
    bool syntaxHighlightingAvailable() const {
        return m_syntaxHighlighter && m_syntaxHighlighter->isInitialized();
    }
    
    void invalidateCache() {
        m_cacheInvalid = true;
    }
    
private:
    struct GlobalLineInfo {
        int globalIndex = 0;
        int sectionIndex = 0;
        int localIndex = 0;
        float yOffset = 0.0f;
    };
    
    void rebuildLineManager() {
        m_lineOffsets.clear();
        m_lineOffsets.reserve(m_globalLines.size());
        
        for (const auto& line : m_globalLines) {
            m_lineOffsets.push_back(line.yOffset);
        }
    }
    
    void parseSyntaxAsync() {
        if (!m_syntaxHighlighter || !m_syntaxHighlighter->isInitialized()) {
            return;
        }
        
        m_syntaxColorCache.clear();
        
        int globalLineIdx = 0;
        for (const auto& section : m_sections) {
            if (section.language.empty()) {
                globalLineIdx += static_cast<int>(section.lines.size());
                continue;
            }
            
            std::string fullContent;
            for (const auto& line : section.lines) {
                fullContent += line.content + "\n";
            }
            
            auto tokens = m_syntaxHighlighter->highlight(fullContent, section.language);
            
            std::vector<size_t> lineStarts;
            lineStarts.push_back(0);
            for (size_t i = 0; i < fullContent.size(); ++i) {
                if (fullContent[i] == '\n') {
                    lineStarts.push_back(i + 1);
                }
            }
            
            for (const auto& token : tokens) {
                size_t lineIdx = std::upper_bound(lineStarts.begin(), lineStarts.end(), 
                    token.start) - lineStarts.begin() - 1;
                
                if (lineIdx < section.lines.size()) {
                    SyntaxColorToken colorToken;
                    colorToken.start = token.start - lineStarts[lineIdx];
                    colorToken.end = token.end - lineStarts[lineIdx];
                    colorToken.color = {
                        token.color.r / 255.0f,
                        token.color.g / 255.0f,
                        token.color.b / 255.0f,
                        token.color.a / 255.0f
                    };
                    
                    m_syntaxColorCache[globalLineIdx + static_cast<int>(lineIdx)].push_back(colorToken);
                }
            }
            
            globalLineIdx += static_cast<int>(section.lines.size());
        }
    }
    
    void generateBackgrounds(float viewportTop, float viewportBottom) {
        float sectionWidth = static_cast<float>(m_viewportWidth) - 
            DiffRenderer::kHorizontalPadding * 2.0f;
        
        for (size_t sectionIdx = 0; sectionIdx < m_sections.size(); ++sectionIdx) {
            const auto& section = m_sections[sectionIdx];
            
            if (section.yOffset + section.height < viewportTop ||
                section.yOffset > viewportBottom) {
                continue;
            }
            
            DiffRectInstance sectionBg;
            sectionBg.originX = DiffRenderer::kHorizontalPadding;
            sectionBg.originY = section.yOffset;
            sectionBg.sizeX = sectionWidth;
            sectionBg.sizeY = section.height;
            sectionBg.colorR = m_colors.headerBg.r;
            sectionBg.colorG = m_colors.headerBg.g;
            sectionBg.colorB = m_colors.headerBg.b;
            sectionBg.colorA = m_colors.headerBg.a;
            sectionBg.cornerRadius = 6.0f;
            sectionBg.borderWidth = 1.0f;
            sectionBg.borderColorR = m_colors.sectionBorder.r;
            sectionBg.borderColorG = m_colors.sectionBorder.g;
            sectionBg.borderColorB = m_colors.sectionBorder.b;
            sectionBg.borderColorA = m_colors.sectionBorder.a;
            m_cachedRectInstances.push_back(sectionBg);
            
            float contentY = section.yOffset + DiffRenderer::kHeaderHeight;
            float contentHeight = section.height - DiffRenderer::kHeaderHeight - 
                DiffRenderer::kFooterHeight;
            
            DiffRectInstance contentBg;
            contentBg.originX = DiffRenderer::kHorizontalPadding + 1.0f;
            contentBg.originY = contentY;
            contentBg.sizeX = sectionWidth - 2.0f;
            contentBg.sizeY = contentHeight;
            contentBg.colorR = 0.05f;
            contentBg.colorG = 0.05f;
            contentBg.colorB = 0.05f;
            contentBg.colorA = 1.0f;
            m_cachedRectInstances.push_back(contentBg);
            
            DiffRectInstance gutterBg;
            gutterBg.originX = DiffRenderer::kHorizontalPadding + 1.0f;
            gutterBg.originY = contentY;
            gutterBg.sizeX = DiffRenderer::kGutterWidth - 2.0f;
            gutterBg.sizeY = contentHeight;
            gutterBg.colorR = m_colors.gutterBg.r;
            gutterBg.colorG = m_colors.gutterBg.g;
            gutterBg.colorB = m_colors.gutterBg.b;
            gutterBg.colorA = m_colors.gutterBg.a;
            m_cachedRectInstances.push_back(gutterBg);
            
            for (size_t lineIdx = 0; lineIdx < section.lines.size(); ++lineIdx) {
                const auto& line = section.lines[lineIdx];
                float lineY = contentY + static_cast<float>(lineIdx) * m_lineHeight;
                
                if (lineY + m_lineHeight < viewportTop || lineY > viewportBottom) {
                    continue;
                }
                
                RGBA bgColor = m_colors.contextBg;
                if (line.type == DiffLineType::Added) {
                    bgColor = m_colors.addedBg;
                } else if (line.type == DiffLineType::Removed) {
                    bgColor = m_colors.removedBg;
                }
                
                if (bgColor.a > 0.01f) {
                    DiffRectInstance lineBg;
                    lineBg.originX = DiffRenderer::kHorizontalPadding + DiffRenderer::kGutterWidth;
                    lineBg.originY = lineY;
                    lineBg.sizeX = sectionWidth - DiffRenderer::kGutterWidth - 1.0f;
                    lineBg.sizeY = m_lineHeight;
                    lineBg.colorR = bgColor.r;
                    lineBg.colorG = bgColor.g;
                    lineBg.colorB = bgColor.b;
                    lineBg.colorA = bgColor.a;
                    m_cachedRectInstances.push_back(lineBg);
                    
                    DiffRectInstance gutterLineBg;
                    gutterLineBg.originX = DiffRenderer::kHorizontalPadding + 1.0f;
                    gutterLineBg.originY = lineY;
                    gutterLineBg.sizeX = DiffRenderer::kGutterWidth - 2.0f;
                    gutterLineBg.sizeY = m_lineHeight;
                    gutterLineBg.colorR = bgColor.r;
                    gutterLineBg.colorG = bgColor.g;
                    gutterLineBg.colorB = bgColor.b;
                    gutterLineBg.colorA = bgColor.a;
                    m_cachedRectInstances.push_back(gutterLineBg);
                }
            }
        }
    }
    
    void generateText(float viewportTop, float viewportBottom) {
        if (!m_fontAtlas || !m_fontAtlas->isValid()) return;
        
        float baselineRatio = 0.78f;
        float textVerticalOffset = m_lineHeight * 0.25f;
        
        for (size_t sectionIdx = 0; sectionIdx < m_sections.size(); ++sectionIdx) {
            const auto& section = m_sections[sectionIdx];
            
            if (section.yOffset + section.height < viewportTop ||
                section.yOffset > viewportBottom) {
                continue;
            }
            
            float headerY = section.yOffset;
            float headerBaselineY = headerY + (DiffRenderer::kHeaderHeight * 0.6f);
            
            std::string headerText = section.filename.empty() ? "Unknown file" : section.filename;
            float headerX = DiffRenderer::kHorizontalPadding + 12.0f;
            
            for (char c : headerText) {
                if (c == ' ' || c == '\t') {
                    headerX += m_monoAdvance;
                    continue;
                }
                
                const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                if (!glyph) continue;
                
                DiffInstanceData inst;
                inst.originX = headerX;
                inst.originY = headerBaselineY - glyph->bearing.y;
                inst.sizeX = glyph->size.x;
                inst.sizeY = glyph->size.y;
                inst.uvMinX = glyph->uvMin.x;
                inst.uvMinY = glyph->uvMin.y;
                inst.uvMaxX = glyph->uvMax.x;
                inst.uvMaxY = glyph->uvMax.y;
                inst.colorR = m_colors.textDefault.r;
                inst.colorG = m_colors.textDefault.g;
                inst.colorB = m_colors.textDefault.b;
                inst.colorA = m_colors.textDefault.a;
                
                m_cachedBoldInstances.push_back(inst);
                headerX += glyph->advance;
            }
            
            float sectionScrollX = horizontalScroll(static_cast<int>(sectionIdx));
            float contentY = section.yOffset + DiffRenderer::kHeaderHeight;
            
            int globalLineBase = 0;
            for (size_t i = 0; i < sectionIdx; ++i) {
                globalLineBase += static_cast<int>(m_sections[i].lines.size());
            }
            
            for (size_t lineIdx = 0; lineIdx < section.lines.size(); ++lineIdx) {
                const auto& line = section.lines[lineIdx];
                float lineY = contentY + static_cast<float>(lineIdx) * m_lineHeight;
                
                if (lineY + m_lineHeight < viewportTop || lineY > viewportBottom) {
                    continue;
                }
                
                float baselineY = std::floor(lineY + (m_lineHeight * baselineRatio) + textVerticalOffset);
                
                float gutterX = DiffRenderer::kHorizontalPadding + 4.0f;
                if (line.oldLineNumber) {
                    std::string numStr = std::to_string(*line.oldLineNumber);
                    for (char c : numStr) {
                        const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                        if (!glyph) continue;
                        
                        DiffInstanceData inst;
                        inst.originX = gutterX;
                        inst.originY = baselineY - glyph->bearing.y;
                        inst.sizeX = glyph->size.x;
                        inst.sizeY = glyph->size.y;
                        inst.uvMinX = glyph->uvMin.x;
                        inst.uvMinY = glyph->uvMin.y;
                        inst.uvMaxX = glyph->uvMax.x;
                        inst.uvMaxY = glyph->uvMax.y;
                        inst.colorR = m_colors.gutterText.r;
                        inst.colorG = m_colors.gutterText.g;
                        inst.colorB = m_colors.gutterText.b;
                        inst.colorA = m_colors.gutterText.a;
                        
                        m_cachedTextInstances.push_back(inst);
                        gutterX += glyph->advance;
                    }
                }
                
                float gutterHalf = DiffRenderer::kGutterWidth / 2.0f;
                gutterX = DiffRenderer::kHorizontalPadding + gutterHalf;
                if (line.newLineNumber) {
                    std::string numStr = std::to_string(*line.newLineNumber);
                    for (char c : numStr) {
                        const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                        if (!glyph) continue;
                        
                        DiffInstanceData inst;
                        inst.originX = gutterX;
                        inst.originY = baselineY - glyph->bearing.y;
                        inst.sizeX = glyph->size.x;
                        inst.sizeY = glyph->size.y;
                        inst.uvMinX = glyph->uvMin.x;
                        inst.uvMinY = glyph->uvMin.y;
                        inst.uvMaxX = glyph->uvMax.x;
                        inst.uvMaxY = glyph->uvMax.y;
                        inst.colorR = m_colors.gutterText.r;
                        inst.colorG = m_colors.gutterText.g;
                        inst.colorB = m_colors.gutterText.b;
                        inst.colorA = m_colors.gutterText.a;
                        
                        m_cachedTextInstances.push_back(inst);
                        gutterX += glyph->advance;
                    }
                }
                
                int globalLineIdx = globalLineBase + static_cast<int>(lineIdx);
                std::vector<SyntaxColorToken> syntaxColors;
                auto cacheIt = m_syntaxColorCache.find(globalLineIdx);
                if (cacheIt != m_syntaxColorCache.end()) {
                    syntaxColors = cacheIt->second;
                }
                
                float textX = DiffRenderer::kHorizontalPadding + DiffRenderer::kGutterWidth + 
                    10.0f - sectionScrollX;
                
                for (size_t charIdx = 0; charIdx < line.content.size(); ++charIdx) {
                    char c = line.content[charIdx];
                    
                    if (c == ' ') {
                        textX += m_monoAdvance;
                        continue;
                    }
                    if (c == '\t') {
                        textX += m_monoAdvance * 4.0f;
                        continue;
                    }
                    
                    const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                    if (!glyph) {
                        textX += m_monoAdvance;
                        continue;
                    }
                    
                    RGBA textColor = m_colors.textDefault;
                    for (const auto& token : syntaxColors) {
                        if (charIdx >= token.start && charIdx < token.end) {
                            textColor = token.color;
                            break;
                        }
                    }
                    
                    DiffInstanceData inst;
                    inst.originX = textX;
                    inst.originY = baselineY - glyph->bearing.y;
                    inst.sizeX = glyph->size.x;
                    inst.sizeY = glyph->size.y;
                    inst.uvMinX = glyph->uvMin.x;
                    inst.uvMinY = glyph->uvMin.y;
                    inst.uvMaxX = glyph->uvMax.x;
                    inst.uvMaxY = glyph->uvMax.y;
                    inst.colorR = textColor.r;
                    inst.colorG = textColor.g;
                    inst.colorB = textColor.b;
                    inst.colorA = textColor.a;
                    
                    m_cachedTextInstances.push_back(inst);
                    textX += glyph->advance;
                }
            }
        }
    }
    
    bool m_initialized = false;
    QOpenGLFunctions* m_gl = nullptr;
    
    std::unique_ptr<FontAtlas> m_fontAtlas;
    std::unique_ptr<highlighting::SyntaxHighlighter> m_syntaxHighlighter;
    
    int m_viewportWidth = 800;
    int m_viewportHeight = 600;
    float m_devicePixelRatio = 1.0f;
    
    float m_lineHeight = 18.0f;
    float m_monoAdvance = 8.0f;
    
    std::vector<ParsedDiffSection> m_sections;
    std::vector<GlobalLineInfo> m_globalLines;
    std::vector<float> m_lineOffsets;
    float m_totalHeight = 0.0f;
    
    std::unordered_map<int, std::vector<SyntaxColorToken>> m_syntaxColorCache;
    std::unordered_map<int, float> m_horizontalScrolls;
    
    DiffColors m_colors;
    
    TextPosition m_selectionStart;
    TextPosition m_selectionEnd;
    bool m_hasSelection = false;
    
    std::vector<DiffInstanceData> m_cachedTextInstances;
    std::vector<DiffInstanceData> m_cachedBoldInstances;
    std::vector<DiffRectInstance> m_cachedRectInstances;
    float m_cachedViewportTop = -1.0f;
    float m_cachedViewportBottom = -1.0f;
    bool m_cacheInvalid = true;
};

DiffRenderer::DiffRenderer() : m_impl(std::make_unique<Impl>()) {}

DiffRenderer::~DiffRenderer() = default;

DiffRenderer::DiffRenderer(DiffRenderer&&) noexcept = default;
DiffRenderer& DiffRenderer::operator=(DiffRenderer&&) noexcept = default;

bool DiffRenderer::initialize() { return m_impl->initialize(); }
bool DiffRenderer::isInitialized() const { return m_impl->isInitialized(); }

void DiffRenderer::setViewportSize(int width, int height, float devicePixelRatio) {
    m_impl->setViewportSize(width, height, devicePixelRatio);
}

ViewportSize DiffRenderer::viewportSize() const { return m_impl->viewportSize(); }
float DiffRenderer::monoAdvance() const { return m_impl->monoAdvance(); }
float DiffRenderer::lineHeight() const { return m_impl->lineHeight(); }

void DiffRenderer::setDiffSections(const std::vector<DiffSection>& sections) {
    m_impl->setDiffSections(sections);
}

int DiffRenderer::sectionCount() const { return m_impl->sectionCount(); }
float DiffRenderer::totalContentHeight() const { return m_impl->totalContentHeight(); }

std::vector<DiffLineInfo> DiffRenderer::visibleLines(float viewportTop, float viewportBottom) const {
    return m_impl->visibleLines(viewportTop, viewportBottom);
}

RenderResult DiffRenderer::generateRenderData(float viewportTop, float viewportBottom) {
    return m_impl->generateRenderData(viewportTop, viewportBottom);
}

void DiffRenderer::setHorizontalScroll(int sectionIndex, float offset) {
    m_impl->setHorizontalScroll(sectionIndex, offset);
}

float DiffRenderer::horizontalScroll(int sectionIndex) const {
    return m_impl->horizontalScroll(sectionIndex);
}

float DiffRenderer::maxHorizontalScroll(int sectionIndex) const {
    return m_impl->maxHorizontalScroll(sectionIndex);
}

void DiffRenderer::setSelection(const TextPosition& start, const TextPosition& end) {
    m_impl->setSelection(start, end);
}

void DiffRenderer::clearSelection() { m_impl->clearSelection(); }
TextSelection DiffRenderer::selection() const { return m_impl->selection(); }
std::string DiffRenderer::selectedText() const { return m_impl->selectedText(); }

bool DiffRenderer::syntaxHighlightingAvailable() const {
    return m_impl->syntaxHighlightingAvailable();
}

void DiffRenderer::invalidateCache() { m_impl->invalidateCache(); }

}  // namespace jules
