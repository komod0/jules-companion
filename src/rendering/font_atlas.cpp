/**
 * Font Atlas Implementation
 * 
 * Uses FreeType for glyph rasterization and generates an OpenGL texture atlas.
 * Port of Mac's FontAtlasManager.swift.
 */

#include "rendering/font_atlas.h"

#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QDebug>
#include <QFont>
#include <QFontDatabase>

#include <ft2build.h>
#include FT_FREETYPE_H

#include <cmath>
#include <algorithm>
#include <unordered_map>

namespace jules {

// =============================================================================
// Implementation
// =============================================================================

struct FontAtlas::Impl {
    FT_Library ftLibrary = nullptr;
    FT_Face ftFace = nullptr;
    
    GLuint textureId = 0;
    int textureWidth = 0;
    int textureHeight = 0;
    
    float baseFontSize = 12.0f;
    float scale = 1.0f;
    float monoAdvanceValue = 8.0f;
    float lineHeightValue = 18.0f;
    
    // Fast-path lookup for common characters (0-255)
    std::array<GlyphDescriptor, 256> fastGlyphs{};
    std::array<bool, 256> fastValid{};
    
    // Map for other Unicode characters
    std::unordered_map<char32_t, GlyphDescriptor> otherGlyphs;

    bool valid = false;
    
    ~Impl() {
        cleanup();
    }
    
    void cleanup() {
        if (textureId != 0) {
            auto* f = QOpenGLContext::currentContext()->functions();
            if (f) {
                f->glDeleteTextures(1, &textureId);
            }
            textureId = 0;
        }
        
        if (ftFace) {
            FT_Done_Face(ftFace);
            ftFace = nullptr;
        }
        
        if (ftLibrary) {
            FT_Done_FreeType(ftLibrary);
            ftLibrary = nullptr;
        }
        
        valid = false;
    }
    
    bool initFreeType() {
        if (FT_Init_FreeType(&ftLibrary)) {
            qWarning() << "FontAtlas: Failed to initialize FreeType";
            return false;
        }
        return true;
    }
    
    bool loadFont(float fontSize, float displayScale) {
        baseFontSize = fontSize;
        scale = displayScale;
        
        // Try common monospace font paths (premium fonts first, then fallbacks)
        // Includes Nerd Font variants (common on Arch/distros with nerd-fonts packages)
        const char* fontPaths[] = {
            // JetBrains Mono (standard)
            "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
            "/usr/share/fonts/jetbrains-mono/JetBrainsMono-Regular.ttf",
            "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
            "/usr/share/fonts/OTF/JetBrainsMono-Regular.otf",
            "/usr/local/share/fonts/JetBrainsMono-Regular.ttf",
            // JetBrains Mono (Nerd Font variants)
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
            // Fira Code (standard)
            "/usr/share/fonts/TTF/FiraCode-Regular.ttf",
            "/usr/share/fonts/fira-code/FiraCode-Regular.ttf",
            "/usr/share/fonts/truetype/fira-code/FiraCode-Regular.ttf",
            "/usr/share/fonts/OTF/FiraCode-Regular.otf",
            "/usr/local/share/fonts/FiraCode-Regular.ttf",
            // Fira Code (Nerd Font variants)
            "/usr/share/fonts/TTF/FiraCodeNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/FiraCodeNerdFont-Regular.ttf",
            // Cascadia Code
            "/usr/share/fonts/TTF/CascadiaCode.ttf",
            "/usr/share/fonts/cascadia-code/CascadiaCode.ttf",
            "/usr/share/fonts/truetype/cascadia-code/CascadiaCode.ttf",
            "/usr/share/fonts/OTF/CascadiaCode.otf",
            "/usr/local/share/fonts/CascadiaCode.ttf",
            // Source Code Pro
            "/usr/share/fonts/TTF/SourceCodePro-Regular.ttf",
            "/usr/share/fonts/adobe-source-code-pro/SourceCodePro-Regular.ttf",
            "/usr/share/fonts/truetype/adobe-source-code-pro/SourceCodePro-Regular.ttf",
            "/usr/share/fonts/OTF/SourceCodePro-Regular.otf",
            "/usr/local/share/fonts/SourceCodePro-Regular.ttf",
            // Hack
            "/usr/share/fonts/TTF/Hack-Regular.ttf",
            "/usr/share/fonts/hack/Hack-Regular.ttf",
            "/usr/share/fonts/truetype/hack/Hack-Regular.ttf",
            "/usr/local/share/fonts/Hack-Regular.ttf",
            // DejaVu Sans Mono (fallback)
            "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
            // Liberation Mono (fallback)
            "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
            // Noto Sans Mono (fallback)
            "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
            "/usr/share/fonts/google-noto/NotoSansMono-Regular.ttf",
            nullptr
        };
        
        FT_Error error = 1;
        for (int i = 0; fontPaths[i] != nullptr; ++i) {
            error = FT_New_Face(ftLibrary, fontPaths[i], 0, &ftFace);
            if (error == 0) {
                qDebug() << "FontAtlas: Loaded font from" << fontPaths[i];
                break;
            }
        }
        
        if (error != 0) {
            qWarning() << "FontAtlas: Could not load any monospace font";
            return false;
        }
        
        // Set pixel size (fontSize * scale for HiDPI)
        int pixelSize = static_cast<int>(fontSize * displayScale);
        if (FT_Set_Pixel_Sizes(ftFace, 0, pixelSize)) {
            qWarning() << "FontAtlas: Failed to set pixel size";
            return false;
        }
        
        return true;
    }
    
    bool buildAtlas() {
        auto* gl = QOpenGLContext::currentContext()->functions();
        if (!gl) {
            qWarning() << "FontAtlas: No OpenGL context";
            return false;
        }
        
        // Collect characters to include in the atlas
        std::vector<char32_t> chars;
        // Basic Latin (32-126)
        for (char32_t c = 32; c <= 126; ++c) chars.push_back(c);
        // Latin-1 Supplement (160-255)
        for (char32_t c = 160; c <= 255; ++c) chars.push_back(c);
        // Common coding symbols
        for (char32_t c : {char32_t(0x2026), char32_t(0x2192), char32_t(0x2713), char32_t(0x2717)}) chars.push_back(c);

        int numChars = static_cast<int>(chars.size());
        
        // Calculate grid size for atlas
        int gridSize = static_cast<int>(std::ceil(std::sqrt(numChars)));
        
        // Get font metrics
        float height = ftFace->size->metrics.height / 64.0f;
        lineHeightValue = height / scale;
        
        // Find maximum glyph dimensions across all selected characters
        int maxWidth = 0;
        int maxHeight = 0;
        for (char32_t c : chars) {
            if (FT_Load_Char(ftFace, c, FT_LOAD_RENDER)) continue;
            maxWidth = std::max(maxWidth, static_cast<int>(ftFace->glyph->bitmap.width));
            maxHeight = std::max(maxHeight, static_cast<int>(ftFace->glyph->bitmap.rows));
        }
        
        // Add padding
        int padding = 4;
        int cellWidth = maxWidth + padding * 2;
        int cellHeight = maxHeight + padding * 2;
        
        textureWidth = gridSize * cellWidth;
        textureHeight = gridSize * cellHeight;
        
        textureWidth = std::max(textureWidth, 256);
        textureHeight = std::max(textureHeight, 256);
        
        std::vector<unsigned char> atlasData(textureWidth * textureHeight, 0);
        
        fastValid.fill(false);
        otherGlyphs.clear();
        
        int charIndex = 0;
        for (char32_t c : chars) {
            if (FT_Load_Char(ftFace, c, FT_LOAD_RENDER)) {
                charIndex++;
                continue;
            }
            
            FT_GlyphSlot g = ftFace->glyph;
            int row = charIndex / gridSize;
            int col = charIndex % gridSize;
            int atlasX = col * cellWidth + padding;
            int atlasY = row * cellHeight + padding;
            
            for (unsigned int y = 0; y < g->bitmap.rows; ++y) {
                for (unsigned int x = 0; x < g->bitmap.width; ++x) {
                    int destX = atlasX + x;
                    int destY = atlasY + y;
                    if (destX < textureWidth && destY < textureHeight) {
                        atlasData[destY * textureWidth + destX] = 
                            g->bitmap.buffer[y * g->bitmap.pitch + x];
                    }
                }
            }
            
            float uMin = static_cast<float>(col * cellWidth) / textureWidth;
            float vMin = static_cast<float>(row * cellHeight) / textureHeight;
            float uMax = static_cast<float>((col + 1) * cellWidth) / textureWidth;
            float vMax = static_cast<float>((row + 1) * cellHeight) / textureHeight;
            
            GlyphDescriptor desc;
            desc.glyphIndex = FT_Get_Char_Index(ftFace, c);
            desc.uvMin = {uMin, vMin};
            desc.uvMax = {uMax, vMax};
            desc.size = { static_cast<float>(cellWidth) / scale, static_cast<float>(cellHeight) / scale };
            desc.bearing = { static_cast<float>(g->bitmap_left) / scale, static_cast<float>(g->bitmap_top + padding) / scale };
            desc.advance = static_cast<float>(g->advance.x >> 6) / scale;
            
            if (c < 256) {
                fastGlyphs[c] = desc;
                fastValid[c] = true;
            } else {
                otherGlyphs[c] = desc;
            }
            
            charIndex++;
        }
        
        if (fastValid['M']) monoAdvanceValue = fastGlyphs['M'].advance;
        else if (fastValid['0']) monoAdvanceValue = fastGlyphs['0'].advance;
        
        // Create OpenGL texture
        gl->glGenTextures(1, &textureId);
        gl->glBindTexture(GL_TEXTURE_2D, textureId);
        
        // Set texture parameters
        gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        
        // Upload texture data (R8 format)
        gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl->glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, textureWidth, textureHeight, 
                         0, GL_RED, GL_UNSIGNED_BYTE, atlasData.data());
        
        gl->glBindTexture(GL_TEXTURE_2D, 0);
        
        valid = true;
        qDebug() << "FontAtlas: Built atlas" << textureWidth << "x" << textureHeight 
                 << "with" << numChars << "glyphs";
        
        return true;
    }
};

// =============================================================================
// Public API
// =============================================================================

FontAtlas::FontAtlas()
    : m_impl(std::make_unique<Impl>())
{
}

FontAtlas::~FontAtlas() = default;

FontAtlas::FontAtlas(FontAtlas&&) noexcept = default;
FontAtlas& FontAtlas::operator=(FontAtlas&&) noexcept = default;

bool FontAtlas::initialize(float fontSize, float scale) {
    m_impl->cleanup();
    
    if (!m_impl->initFreeType()) {
        return false;
    }
    
    if (!m_impl->loadFont(fontSize, scale)) {
        return false;
    }
    
    if (!m_impl->buildAtlas()) {
        return false;
    }
    
    return true;
}

bool FontAtlas::isValid() const {
    return m_impl->valid;
}

GLuint FontAtlas::textureId() const {
    return m_impl->textureId;
}

int FontAtlas::textureWidth() const {
    return m_impl->textureWidth;
}

int FontAtlas::textureHeight() const {
    return m_impl->textureHeight;
}

std::optional<GlyphDescriptor> FontAtlas::getGlyph(char32_t c) const {
    if (c < 256) {
        if (m_impl->fastValid[c]) return m_impl->fastGlyphs[c];
    } else {
        auto it = m_impl->otherGlyphs.find(c);
        if (it != m_impl->otherGlyphs.end()) return it->second;
    }
    return std::nullopt;
}

const GlyphDescriptor* FontAtlas::getASCIIGlyph(char32_t c) const {
    if (c < 256) {
        if (m_impl->fastValid[c]) return &m_impl->fastGlyphs[c];
    } else {
        auto it = m_impl->otherGlyphs.find(c);
        if (it != m_impl->otherGlyphs.end()) return &it->second;
    }
    return nullptr;
}

float FontAtlas::monoAdvance() const {
    return m_impl->monoAdvanceValue;
}

float FontAtlas::lineHeight() const {
    return m_impl->lineHeightValue;
}

void FontAtlas::updateScale(float newScale) {
    if (std::abs(m_impl->scale - newScale) > 0.1f) {
        m_impl->cleanup();
        m_impl->initFreeType();
        m_impl->loadFont(m_impl->baseFontSize, newScale);
        m_impl->buildAtlas();
    }
}

void FontAtlas::updateFontSize(float newFontSize) {
    if (std::abs(m_impl->baseFontSize - newFontSize) > 0.1f) {
        m_impl->cleanup();
        m_impl->initFreeType();
        m_impl->loadFont(newFontSize, m_impl->scale);
        m_impl->buildAtlas();
    }
}

} // namespace jules
