#include "rendering/diff_renderer.h"
#include "rendering/shared_syntax_cache.h"
#include "rendering/font_atlas.h"
#include "highlighting/syntax_highlighter.h"
#include "data/settings_manager.h"

#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QDebug>

#include <algorithm>
#include <cmath>
#include <sstream>
#include <mutex>
#include <future>
#include <atomic>

namespace jules {

namespace {

struct DiffColors {
    RGBA addedBg;
    RGBA removedBg;
    RGBA contextBg;
    RGBA headerBg;
    RGBA textDefault;
    RGBA gutterText;
    RGBA gutterBg;
    RGBA sectionBorder;
    RGBA selectionBg;
    RGBA highlightBg;
    RGBA statsAddedText;
    RGBA statsAddedBg;
    RGBA statsRemovedText;
    RGBA statsRemovedBg;
    RGBA inlineAddedBg;
    RGBA inlineRemovedBg;
    float contentBgValue = 0.05f; // used for the content area background
};

RGBA qColorToRGBA(const QColor& c) {
    return {static_cast<float>(c.redF()), static_cast<float>(c.greenF()),
            static_cast<float>(c.blueF()), static_cast<float>(c.alphaF())};
}

DiffColors createColorsFromTheme(Theme theme) {
    ThemeColors tc = AppColors::colorsForTheme(theme);
    DiffColors c;
    c.addedBg       = qColorToRGBA(tc.diffAddedBg);
    c.removedBg     = qColorToRGBA(tc.diffRemovedBg);
    c.contextBg     = {0.0f, 0.0f, 0.0f, 0.0f};
    c.headerBg      = qColorToRGBA(tc.diffHeaderBg);
    c.textDefault   = qColorToRGBA(tc.textPrimary);
    c.gutterText    = qColorToRGBA(tc.diffGutterText);
    c.gutterBg      = qColorToRGBA(tc.diffGutterBg);
    c.sectionBorder = qColorToRGBA(tc.separator);

    QColor sel = tc.accent;
    sel.setAlphaF(tc.isDark ? 0.3f : 0.2f);
    c.selectionBg   = qColorToRGBA(sel);

    c.highlightBg   = qColorToRGBA(tc.accentLight);
    c.statsAddedText   = qColorToRGBA(AppColors::running(tc.isDark));
    c.statsAddedBg     = c.statsAddedText;
    c.statsAddedBg.a   = 0.15f;
    c.statsRemovedText = qColorToRGBA(AppColors::destructive(tc.isDark));
    c.statsRemovedBg   = c.statsRemovedText;
    c.statsRemovedBg.a = 0.15f;
    c.inlineAddedBg    = qColorToRGBA(tc.diffInlineAddedBg);
    c.inlineRemovedBg  = qColorToRGBA(tc.diffInlineRemovedBg);
    c.contentBgValue   = static_cast<float>(tc.backgroundDark.redF()); // Use backgroundDark for content
    return c;
}

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

bool parseHunkHeader(const std::string& line, int& oldLine, int& newLine) {
    // line format: @@ -OLD[,COUNT] +NEW[,COUNT] @@...
    if (line.size() < 8 || line[0] != '@' || line[1] != '@' || line[2] != ' ' || line[3] != '-')
        return false;

    size_t pos = 4;
    // Parse old line number
    size_t numStart = pos;
    while (pos < line.size() && line[pos] >= '0' && line[pos] <= '9') ++pos;
    if (pos == numStart) return false;
    oldLine = std::stoi(line.substr(numStart, pos - numStart));

    // Skip optional ,count
    if (pos < line.size() && line[pos] == ',') {
        ++pos;
        while (pos < line.size() && line[pos] >= '0' && line[pos] <= '9') ++pos;
    }

    // Expect " +"
    if (pos + 1 >= line.size() || line[pos] != ' ' || line[pos + 1] != '+') return false;
    pos += 2;

    // Parse new line number
    numStart = pos;
    while (pos < line.size() && line[pos] >= '0' && line[pos] <= '9') ++pos;
    if (pos == numStart) return false;
    newLine = std::stoi(line.substr(numStart, pos - numStart));

    // Skip optional ,count
    if (pos < line.size() && line[pos] == ',') {
        ++pos;
        while (pos < line.size() && line[pos] >= '0' && line[pos] <= '9') ++pos;
    }

    // Should have " @@" next
    if (pos + 2 >= line.size() || line[pos] != ' ' || line[pos + 1] != '@' || line[pos + 2] != '@')
        return false;

    return true;
}

ParsedPatchResult parsePatch(const std::string& patch, const std::string& language,
                             const std::string& filename) {
    ParsedPatchResult result;
    result.language = language;
    
    std::istringstream stream(patch);
    std::string line;
    
    int oldLineNum = 0;
    int newLineNum = 0;
    bool inHunk = false;
    
    while (std::getline(stream, line)) {
        if (line.empty()) continue;

        if (line.rfind("diff --git", 0) == 0 ||
            line.rfind("index ", 0) == 0 ||
            line.rfind("--- ", 0) == 0 ||
            line.rfind("+++ ", 0) == 0) {
            continue;
        }

        int parsedOld = 0, parsedNew = 0;
        if (parseHunkHeader(line, parsedOld, parsedNew)) {
            oldLineNum = parsedOld;
            newLineNum = parsedNew;
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

    // Compute character-level inline diffs for paired removed/added lines
    for (size_t i = 0; i + 1 < result.lines.size(); ++i) {
        if (result.lines[i].type == DiffLineType::Removed &&
            result.lines[i + 1].type == DiffLineType::Added) {
            const std::string& oldText = result.lines[i].content;
            const std::string& newText = result.lines[i + 1].content;

            // Find longest common prefix
            size_t prefixLen = 0;
            size_t minLen = std::min(oldText.size(), newText.size());
            while (prefixLen < minLen && oldText[prefixLen] == newText[prefixLen]) {
                ++prefixLen;
            }

            // Find longest common suffix (not overlapping prefix)
            size_t suffixLen = 0;
            while (suffixLen < minLen - prefixLen &&
                   oldText[oldText.size() - 1 - suffixLen] == newText[newText.size() - 1 - suffixLen]) {
                ++suffixLen;
            }

            // Mark the changed middle range on each line
            size_t oldChangeEnd = oldText.size() - suffixLen;
            size_t newChangeEnd = newText.size() - suffixLen;

            if (prefixLen < oldChangeEnd) {
                result.lines[i].tokenChanges.push_back({prefixLen, oldChangeEnd});
            }
            if (prefixLen < newChangeEnd) {
                result.lines[i + 1].tokenChanges.push_back({prefixLen, newChangeEnd});
            }

            // Skip the added line since it's already been paired
            ++i;
        }
    }

    return result;
}

}  // namespace

class DiffRenderer::Impl {
public:
    Impl() : m_colors(createColorsFromTheme(Theme::Dark)) {}
    ~Impl() {
        if (m_syntaxFuture.valid()) {
            m_syntaxFuture.wait();
        }
    }
    
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
        float fontSize = static_cast<float>(SettingsManager::instance().diffFontSize());
        if (!m_fontAtlas->initialize(fontSize, m_devicePixelRatio)) {
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

        if (m_fontAtlas && std::abs(m_devicePixelRatio - dpr) > 0.01f) {
            m_fontAtlas->updateScale(dpr);
            m_lineHeight = m_fontAtlas->lineHeight();
            m_monoAdvance = m_fontAtlas->monoAdvance();
        }
        m_devicePixelRatio = dpr;

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
        {
            std::lock_guard<std::mutex> lock(m_cacheMutex);
            m_syntaxColorCache.clear();
        }
        m_horizontalScrolls.clear();
        
        float currentY = DiffRenderer::kSectionSpacing;
        int globalLineIndex = 0;
        
        for (size_t sectionIdx = 0; sectionIdx < sections.size(); ++sectionIdx) {
            const auto& section = sections[sectionIdx];
            
            auto parseResult = parsePatch(section.patch, section.language, section.filename);

            // Detect binary/empty sections and inject a synthetic label line
            if (parseResult.lines.empty()) {
                LocalDiffLine binaryLine;
                binaryLine.content = "Binary file";
                binaryLine.type = DiffLineType::Context;
                parseResult.lines.push_back(binaryLine);
            }

            ParsedDiffSection parsedSection;
            parsedSection.filename = section.filename;
            parsedSection.language = section.language;
            parsedSection.yOffset = currentY;
            parsedSection.isBinary = (parseResult.lines.size() == 1 &&
                                      parseResult.lines[0].content == "Binary file");

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
                
                {
                    std::lock_guard<std::mutex> lock(m_cacheMutex);
                    auto cacheIt = m_syntaxColorCache.find(currentLine);
                    if (cacheIt != m_syntaxColorCache.end()) {
                        info.syntaxTokens = cacheIt->second;
                    }
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

        int snappedTop = static_cast<int>(viewportTop);
        int snappedBottom = static_cast<int>(viewportBottom);
        if (m_cachedSnappedTop == snappedTop &&
            m_cachedSnappedBottom == snappedBottom &&
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

        m_cachedSnappedTop = snappedTop;
        m_cachedSnappedBottom = snappedBottom;
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

    void selectAll() {
        if (m_sections.empty()) return;
        m_selectionStart = {0, 0};
        int totalLines = 0;
        int lastLineLen = 0;
        for (const auto& section : m_sections) {
            for (const auto& line : section.lines) {
                lastLineLen = static_cast<int>(line.content.size());
                totalLines++;
            }
        }
        m_selectionEnd = {totalLines - 1, lastLineLen};
        m_hasSelection = true;
        invalidateCache();
    }

    int sectionIndexAtY(float worldY) const {
        for (size_t i = 0; i < m_sections.size(); ++i) {
            const auto& section = m_sections[i];
            float sectionTop = section.yOffset;
            float sectionBottom = section.yOffset + section.height;
            if (worldY >= sectionTop && worldY < sectionBottom) {
                return static_cast<int>(i);
            }
        }
        return -1;
    }

    std::string sectionFilename(int index) const {
        if (index < 0 || index >= static_cast<int>(m_sections.size())) {
            return {};
        }
        return m_sections[index].filename;
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
    
    bool syntaxHighlightingActive() const {
        return m_syntaxHighlightingActive.load();
    }

    void setSharedSyntaxCache(SharedSyntaxCache* cache) {
        m_sharedSyntaxCache = cache;
    }

    void setTheme(Theme theme) {
        if (m_theme == theme) return;
        m_theme = theme;
        ThemeColors tc = AppColors::colorsForTheme(theme);
        m_isDark = tc.isDark;
        m_colors = createColorsFromTheme(theme);
        {
            std::lock_guard<std::mutex> lock(m_cacheMutex);
            m_syntaxColorCache.clear();
        }
        parseSyntaxAsync();
        invalidateCache();
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

        // Increment version to invalidate previous async tasks
        uint32_t currentVersion = ++m_syntaxTaskVersion;

        // Clone needed data for the async thread
        struct TaskData {
            std::string filename;
            std::string language;
            std::vector<std::string> lineContents;
        };
        std::vector<TaskData> tasks;
        tasks.reserve(m_sections.size());
        for (const auto& section : m_sections) {
            TaskData td;
            td.filename = section.filename;
            td.language = section.language;
            for (const auto& line : section.lines) {
                td.lineContents.push_back(line.content);
            }
            tasks.push_back(td);
        }

        auto* highlighter = m_syntaxHighlighter.get();
        auto* sharedCache = m_sharedSyntaxCache;
        bool isDark = m_isDark;

        m_syntaxFuture = std::async(std::launch::async, [this, tasks, highlighter, sharedCache, isDark, currentVersion]() {
            std::unordered_map<int, std::vector<SyntaxColorToken>> localCache;
            int globalLineIdx = 0;

            for (const auto& td : tasks) {
                if (td.language.empty()) {
                    globalLineIdx += static_cast<int>(td.lineContents.size());
                    continue;
                }

                std::string fullContent;
                for (const auto& line : td.lineContents) {
                    fullContent += line + "\n";
                }

                std::size_t contentHash = std::hash<std::string>{}(fullContent);
                bool cacheHit = false;

                if (sharedCache) {
                    SharedSyntaxCache::CacheKey cacheKey{contentHash, td.language, isDark};
                    auto cached = sharedCache->get(cacheKey);
                    if (cached) {
                        cacheHit = true;
                        std::vector<size_t> lineStarts;
                        lineStarts.push_back(0);
                        for (size_t i = 0; i < fullContent.size(); ++i) {
                            if (fullContent[i] == '\n') lineStarts.push_back(i + 1);
                        }

                        for (const auto& colorToken : *cached) {
                            size_t lineIdx = std::upper_bound(lineStarts.begin(), lineStarts.end(),
                                colorToken.start) - lineStarts.begin() - 1;

                            if (lineIdx < td.lineContents.size()) {
                                SyntaxColorToken localToken = colorToken;
                                localToken.start = colorToken.start - lineStarts[lineIdx];
                                localToken.end = colorToken.end - lineStarts[lineIdx];
                                localCache[globalLineIdx + static_cast<int>(lineIdx)].push_back(localToken);
                            }
                        }
                        globalLineIdx += static_cast<int>(td.lineContents.size());
                        continue;
                    }
                }

                auto tokens = highlighter->highlight(fullContent, td.language);

                std::vector<size_t> lineStarts;
                lineStarts.push_back(0);
                for (size_t i = 0; i < fullContent.size(); ++i) {
                    if (fullContent[i] == '\n') lineStarts.push_back(i + 1);
                }

                std::vector<SyntaxColorToken> cacheTokens;
                if (sharedCache) cacheTokens.reserve(tokens.size());

                for (const auto& token : tokens) {
                    size_t lineIdx = std::upper_bound(lineStarts.begin(), lineStarts.end(),
                        token.start) - lineStarts.begin() - 1;

                    if (lineIdx < td.lineContents.size()) {
                        SyntaxColorToken colorToken;
                        colorToken.start = token.start - lineStarts[lineIdx];
                        colorToken.end = token.end - lineStarts[lineIdx];
                        colorToken.color = {
                            token.color.r / 255.0f, token.color.g / 255.0f,
                            token.color.b / 255.0f, token.color.a / 255.0f
                        };
                        localCache[globalLineIdx + static_cast<int>(lineIdx)].push_back(colorToken);
                    }

                    if (sharedCache) {
                        SyntaxColorToken absToken;
                        absToken.start = token.start; absToken.end = token.end;
                        absToken.color = {
                            token.color.r / 255.0f, token.color.g / 255.0f,
                            token.color.b / 255.0f, token.color.a / 255.0f
                        };
                        cacheTokens.push_back(absToken);
                    }
                }

                if (sharedCache && !cacheHit) {
                    SharedSyntaxCache::CacheKey cacheKey{contentHash, td.language, isDark};
                    sharedCache->put(cacheKey, std::move(cacheTokens));
                }

                globalLineIdx += static_cast<int>(td.lineContents.size());
            }

            // Update the main cache if this task is still relevant
            if (currentVersion == m_syntaxTaskVersion) {
                std::lock_guard<std::mutex> lock(m_cacheMutex);
                m_syntaxColorCache = std::move(localCache);
                m_cacheInvalid = true;
                m_syntaxHighlightingActive = false;
            }
        });

        m_syntaxHighlightingActive = true;
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
            contentBg.colorR = m_colors.contentBgValue;
            contentBg.colorG = m_colors.contentBgValue;
            contentBg.colorB = m_colors.contentBgValue;
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

                // Render inline change highlights on top of line backgrounds
                if (!line.tokenChanges.empty()) {
                    RGBA inlineColor = (line.type == DiffLineType::Added)
                        ? m_colors.inlineAddedBg
                        : m_colors.inlineRemovedBg;

                    float sectionScrollX = horizontalScroll(static_cast<int>(sectionIdx));
                    float textStartX = DiffRenderer::kHorizontalPadding +
                        DiffRenderer::kGutterWidth + 10.0f - sectionScrollX;

                    for (const auto& [start, end] : line.tokenChanges) {
                        float rectX = textStartX + static_cast<float>(start) * m_monoAdvance;
                        float rectW = static_cast<float>(end - start) * m_monoAdvance;

                        DiffRectInstance inlineBg;
                        inlineBg.originX = rectX;
                        inlineBg.originY = lineY;
                        inlineBg.sizeX = rectW;
                        inlineBg.sizeY = m_lineHeight;
                        inlineBg.colorR = inlineColor.r;
                        inlineBg.colorG = inlineColor.g;
                        inlineBg.colorB = inlineColor.b;
                        inlineBg.colorA = inlineColor.a;
                        m_cachedRectInstances.push_back(inlineBg);
                    }
                }
            }
        }
    }
    
    void generateText(float viewportTop, float viewportBottom) {
        if (!m_fontAtlas || !m_fontAtlas->isValid()) return;
        
        float baselineRatio = 0.75f;
        
        for (size_t sectionIdx = 0; sectionIdx < m_sections.size(); ++sectionIdx) {
            const auto& section = m_sections[sectionIdx];
            
            if (section.yOffset + section.height < viewportTop ||
                section.yOffset > viewportBottom) {
                continue;
            }
            
            float headerY = section.yOffset;
            float headerBaselineY = headerY + (DiffRenderer::kHeaderHeight * 0.6f);
            
            QString headerText = QString::fromStdString(section.filename.empty() ? "Unknown file" : section.filename);
            float headerX = DiffRenderer::kHorizontalPadding + 12.0f;
            
            for (int i = 0; i < headerText.length(); ++i) {
                char32_t c = headerText[i].unicode();
                if (headerText[i].isHighSurrogate() && i + 1 < headerText.length()) {
                    c = QChar::surrogateToUcs4(headerText[i], headerText[i+1]);
                    i++;
                }

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
            
            // Render stats badges at the right side of the header
            float badgeRightEdge = m_viewportWidth - DiffRenderer::kHorizontalPadding - 8.0f;
            float badgePadX = 6.0f;  // Horizontal padding inside badge
            float badgePadY = 2.0f;  // Vertical padding inside badge
            float badgeSpacing = 6.0f; // Space between badges
            float badgeCornerRadius = 3.0f;
            
            // Render removed badge first (it goes to the left of added)
            if (section.linesRemoved > 0) {
                QString removedStr = "-" + QString::number(section.linesRemoved);
                float textWidth = removedStr.length() * m_monoAdvance;
                float badgeWidth = textWidth + badgePadX * 2.0f;
                float badgeX = badgeRightEdge - badgeWidth;
                float badgeHeight = m_lineHeight * 0.7f;
                float badgeY = headerY + (DiffRenderer::kHeaderHeight * 0.5f) - (badgeHeight / 2.0f);

                // Badge background
                DiffRectInstance badgeBg;
                badgeBg.originX = badgeX;
                badgeBg.originY = badgeY;
                badgeBg.sizeX = badgeWidth;
                badgeBg.sizeY = badgeHeight;
                badgeBg.colorR = m_colors.statsRemovedBg.r;
                badgeBg.colorG = m_colors.statsRemovedBg.g;
                badgeBg.colorB = m_colors.statsRemovedBg.b;
                badgeBg.colorA = m_colors.statsRemovedBg.a;
                badgeBg.cornerRadius = badgeCornerRadius;
                badgeBg.borderWidth = 0.0f;
                badgeBg.borderColorR = badgeBg.borderColorG = badgeBg.borderColorB = badgeBg.borderColorA = 0.0f;
                m_cachedRectInstances.push_back(badgeBg);
                
                // Badge text
                float textX = badgeX + badgePadX;
                float textBaselineY = headerBaselineY;
                for (int i = 0; i < removedStr.length(); ++i) {
                    char32_t c = removedStr[i].unicode();
                    const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                    if (!glyph) { textX += m_monoAdvance; continue; }
                    
                    DiffInstanceData inst;
                    inst.originX = textX;
                    inst.originY = textBaselineY - glyph->bearing.y;
                    inst.sizeX = glyph->size.x;
                    inst.sizeY = glyph->size.y;
                    inst.uvMinX = glyph->uvMin.x;
                    inst.uvMinY = glyph->uvMin.y;
                    inst.uvMaxX = glyph->uvMax.x;
                    inst.uvMaxY = glyph->uvMax.y;
                    inst.colorR = m_colors.statsRemovedText.r;
                    inst.colorG = m_colors.statsRemovedText.g;
                    inst.colorB = m_colors.statsRemovedText.b;
                    inst.colorA = m_colors.statsRemovedText.a;
                    m_cachedBoldInstances.push_back(inst);
                    textX += glyph->advance;
                }
                
                badgeRightEdge = badgeX - badgeSpacing;
            }
            
            // Render added badge
            if (section.linesAdded > 0) {
                QString addedStr = "+" + QString::number(section.linesAdded);
                float textWidth = addedStr.length() * m_monoAdvance;
                float badgeWidth = textWidth + badgePadX * 2.0f;
                float badgeX = badgeRightEdge - badgeWidth;
                float badgeHeight = m_lineHeight * 0.7f;
                float badgeY = headerY + (DiffRenderer::kHeaderHeight * 0.5f) - (badgeHeight / 2.0f);

                // Badge background
                DiffRectInstance badgeBg;
                badgeBg.originX = badgeX;
                badgeBg.originY = badgeY;
                badgeBg.sizeX = badgeWidth;
                badgeBg.sizeY = badgeHeight;
                badgeBg.colorR = m_colors.statsAddedBg.r;
                badgeBg.colorG = m_colors.statsAddedBg.g;
                badgeBg.colorB = m_colors.statsAddedBg.b;
                badgeBg.colorA = m_colors.statsAddedBg.a;
                badgeBg.cornerRadius = badgeCornerRadius;
                badgeBg.borderWidth = 0.0f;
                badgeBg.borderColorR = badgeBg.borderColorG = badgeBg.borderColorB = badgeBg.borderColorA = 0.0f;
                m_cachedRectInstances.push_back(badgeBg);
                
                // Badge text
                float textX = badgeX + badgePadX;
                float textBaselineY = headerBaselineY;
                for (int i = 0; i < addedStr.length(); ++i) {
                    char32_t c = addedStr[i].unicode();
                    const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                    if (!glyph) { textX += m_monoAdvance; continue; }
                    
                    DiffInstanceData inst;
                    inst.originX = textX;
                    inst.originY = textBaselineY - glyph->bearing.y;
                    inst.sizeX = glyph->size.x;
                    inst.sizeY = glyph->size.y;
                    inst.uvMinX = glyph->uvMin.x;
                    inst.uvMinY = glyph->uvMin.y;
                    inst.uvMaxX = glyph->uvMax.x;
                    inst.uvMaxY = glyph->uvMax.y;
                    inst.colorR = m_colors.statsAddedText.r;
                    inst.colorG = m_colors.statsAddedText.g;
                    inst.colorB = m_colors.statsAddedText.b;
                    inst.colorA = m_colors.statsAddedText.a;
                    m_cachedBoldInstances.push_back(inst);
                    textX += glyph->advance;
                }
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
                
                float baselineY = std::floor(lineY + m_lineHeight * baselineRatio);
                
                float gutterX = DiffRenderer::kHorizontalPadding + 4.0f;
                if (line.oldLineNumber) {
                    QString numStr = QString::number(*line.oldLineNumber);
                    for (int i = 0; i < numStr.length(); ++i) {
                        char32_t c = numStr[i].unicode();
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
                    QString numStr = QString::number(*line.newLineNumber);
                    for (int i = 0; i < numStr.length(); ++i) {
                        char32_t c = numStr[i].unicode();
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
                {
                    std::lock_guard<std::mutex> lock(m_cacheMutex);
                    auto cacheIt = m_syntaxColorCache.find(globalLineIdx);
                    if (cacheIt != m_syntaxColorCache.end()) {
                        syntaxColors = cacheIt->second;
                    }
                }
                
                float textX = DiffRenderer::kHorizontalPadding + DiffRenderer::kGutterWidth + 
                    10.0f - sectionScrollX;
                
                const std::string& lineStr = line.content;
                QString qLine = QString::fromStdString(lineStr);
                int qIdx = 0;
                int byteOffset = 0;

                for (int byteIdx = 0; byteIdx < (int)lineStr.length(); ) {
                    char32_t c = qLine[qIdx].unicode();
                    if (qLine[qIdx].isHighSurrogate() && qIdx + 1 < qLine.length()) {
                        c = QChar::surrogateToUcs4(qLine[qIdx], qLine[qIdx+1]);
                    }

                    if (c == ' ') {
                        textX += m_monoAdvance;
                    } else if (c == '\t') {
                        textX += m_monoAdvance * 4.0f;
                    } else {
                        const auto* glyph = m_fontAtlas->getASCIIGlyph(c);
                        if (glyph) {
                            RGBA textColor = m_colors.textDefault;
                            if (!syntaxColors.empty()) {
                                auto it = std::upper_bound(syntaxColors.begin(), syntaxColors.end(), byteOffset,
                                    [](size_t idx, const SyntaxColorToken& tok) { return idx < tok.start; });
                                if (it != syntaxColors.begin()) {
                                    --it;
                                    if (byteOffset < it->end) {
                                        textColor = it->color;
                                    }
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
                        } else {
                            textX += m_monoAdvance;
                        }
                    }
                    
                    // Advance
                    int bytesThisChar = 1;
                    unsigned char lead = static_cast<unsigned char>(lineStr[byteIdx]);
                    if (lead < 0x80) bytesThisChar = 1;
                    else if ((lead & 0xE0) == 0xC0) bytesThisChar = 2;
                    else if ((lead & 0xF0) == 0xE0) bytesThisChar = 3;
                    else if ((lead & 0xF0) == 0xF0) bytesThisChar = 4;
                    
                    byteOffset += bytesThisChar;
                    byteIdx += bytesThisChar;
                    qIdx += (c > 0xFFFF) ? 2 : 1;
                }
            }
        }
    }
    
    bool m_initialized = false;
    QOpenGLFunctions* m_gl = nullptr;
    
    std::unique_ptr<FontAtlas> m_fontAtlas;
    std::unique_ptr<highlighting::SyntaxHighlighter> m_syntaxHighlighter;
    SharedSyntaxCache* m_sharedSyntaxCache = nullptr;
    
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
    mutable std::mutex m_cacheMutex;
    std::atomic<uint32_t> m_syntaxTaskVersion{0};
    std::atomic<bool> m_syntaxHighlightingActive{false};
    std::future<void> m_syntaxFuture;
    std::unordered_map<int, float> m_horizontalScrolls;
    
    DiffColors m_colors;
    Theme m_theme = Theme::Dark;
    bool m_isDark = true;

    TextPosition m_selectionStart;
    TextPosition m_selectionEnd;
    bool m_hasSelection = false;
    
    std::vector<DiffInstanceData> m_cachedTextInstances;
    std::vector<DiffInstanceData> m_cachedBoldInstances;
    std::vector<DiffRectInstance> m_cachedRectInstances;
    int m_cachedSnappedTop = -1;
    int m_cachedSnappedBottom = -1;
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
void DiffRenderer::selectAll() { m_impl->selectAll(); }
TextSelection DiffRenderer::selection() const { return m_impl->selection(); }
std::string DiffRenderer::selectedText() const { return m_impl->selectedText(); }

int DiffRenderer::sectionIndexAtY(float worldY) const { return m_impl->sectionIndexAtY(worldY); }
std::string DiffRenderer::sectionFilename(int sectionIndex) const { return m_impl->sectionFilename(sectionIndex); }

bool DiffRenderer::isSyntaxHighlightingInProgress() const {
    return m_impl->syntaxHighlightingActive();
}

void DiffRenderer::setSharedSyntaxCache(SharedSyntaxCache* cache) {
    m_impl->setSharedSyntaxCache(cache);
}

void DiffRenderer::setTheme(Theme theme) {
    m_impl->setTheme(theme);
}

void DiffRenderer::invalidateCache() { m_impl->invalidateCache(); }

}  // namespace jules
