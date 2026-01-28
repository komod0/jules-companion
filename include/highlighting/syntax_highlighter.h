#pragma once

#include <string>
#include <vector>
#include <map>
#include <future>
#include <memory>
#include <cstdint>

namespace jules::highlighting {

struct Color {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
    uint8_t a = 255;
    
    Color() = default;
    Color(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255)
        : r(r), g(g), b(b), a(a) {}
    
    static Color fromHex(const std::string& hex);
};

struct SyntaxToken {
    size_t start = 0;
    size_t end = 0;
    std::string type;
    Color color;
};

enum class SyntaxType {
    Keyword,
    String,
    Comment,
    Function,
    Type,
    Variable,
    Number,
    Operator,
    Tag,
    Regexp,
    Special,
    Unknown
};

class SyntaxHighlighter {
public:
    SyntaxHighlighter();
    ~SyntaxHighlighter();
    
    SyntaxHighlighter(const SyntaxHighlighter&) = delete;
    SyntaxHighlighter& operator=(const SyntaxHighlighter&) = delete;
    SyntaxHighlighter(SyntaxHighlighter&&) noexcept;
    SyntaxHighlighter& operator=(SyntaxHighlighter&&) noexcept;
    
    bool isInitialized() const;
    std::vector<std::string> availableLanguages() const;
    
    std::vector<SyntaxToken> highlight(const std::string& code, const std::string& language) const;
    std::future<std::vector<SyntaxToken>> highlightAsync(const std::string& code, const std::string& language) const;
    std::map<size_t, std::vector<SyntaxToken>> highlightByLine(const std::string& code, const std::string& language) const;
    
    static Color colorForSyntaxType(SyntaxType type);
    static SyntaxType syntaxTypeFromCapture(const std::string& captureName);
    
private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace jules::highlighting
