/**
 * Font Atlas for OpenGL Text Rendering
 * 
 * Generates a texture atlas containing pre-rendered glyphs using FreeType.
 * Optimized for instanced quad rendering of monospace text.
 * 
 * Port of Mac's FontAtlasManager.swift using FreeType instead of CoreText.
 */

#pragma once

#include <QOpenGLFunctions>

#include <cstdint>
#include <memory>
#include <optional>
#include <array>
#include <string>
#include <vector>

// Forward declare GLuint to avoid OpenGL header dependency
using GLuint = unsigned int;

namespace jules {

/**
 * 2D vector for positions, sizes, UVs
 */
struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

/**
 * Descriptor for a single glyph in the atlas.
 * Contains UV coordinates, size, and advance metrics for text layout.
 */
struct GlyphDescriptor {
    /// Glyph index from FreeType
    unsigned int glyphIndex = 0;
    
    /// UV coordinates in texture (normalized 0-1)
    Vec2 uvMin{0.0f, 0.0f};
    Vec2 uvMax{1.0f, 1.0f};
    
    /// Size in logical points
    Vec2 size{0.0f, 0.0f};
    
    /// Bearing (offset from baseline)
    Vec2 bearing{0.0f, 0.0f};
    
    /// Horizontal advance in logical points
    float advance = 0.0f;
};

/**
 * Font atlas for GPU text rendering.
 * 
 * Generates an R8 texture containing pre-rendered ASCII glyphs.
 * Uses FreeType for font rasterization.
 * 
 * Usage:
 *   FontAtlas atlas;
 *   atlas.initialize(12.0f, 2.0f);  // 12pt font, 2x scale (Retina)
 *   GLuint texId = atlas.textureId();
 *   auto glyph = atlas.getGlyph('A');
 */
class FontAtlas {
public:
    FontAtlas();
    ~FontAtlas();
    
    // Non-copyable, movable
    FontAtlas(const FontAtlas&) = delete;
    FontAtlas& operator=(const FontAtlas&) = delete;
    FontAtlas(FontAtlas&&) noexcept;
    FontAtlas& operator=(FontAtlas&&) noexcept;
    
    /**
     * Initialize the font atlas with given parameters.
     * Must be called after OpenGL context is current.
     * 
     * @param fontSize Base font size in points
     * @param scale Display scale factor (e.g., 2.0 for Retina)
     * @return true if initialization succeeded
     */
    bool initialize(float fontSize, float scale);
    
    /**
     * Check if atlas was successfully initialized
     */
    bool isValid() const;
    
    /**
     * Get the OpenGL texture ID for the atlas
     */
    GLuint textureId() const;
    
    /**
     * Get atlas texture width in pixels
     */
    int textureWidth() const;
    
    /**
     * Get atlas texture height in pixels
     */
    int textureHeight() const;
    
    /**
     * Get glyph descriptor for a character.
     * Returns nullopt for non-ASCII or control characters.
     */
    std::optional<GlyphDescriptor> getGlyph(char c) const;
    
    /**
     * Fast O(1) lookup for ASCII characters (32-126).
     * Returns nullptr for invalid characters.
     * Faster than getGlyph() for hot paths.
     */
    const GlyphDescriptor* getASCIIGlyph(char c) const;
    
    /**
     * Get the monospace advance width (from 'M' character).
     * For monospace fonts, all characters share this advance.
     */
    float monoAdvance() const;
    
    /**
     * Get line height in points.
     * Standard line spacing for the font.
     */
    float lineHeight() const;
    
    /**
     * Update scale factor (triggers atlas rebuild).
     */
    void updateScale(float newScale);
    
    /**
     * Update font size (triggers atlas rebuild).
     */
    void updateFontSize(float newFontSize);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace jules
