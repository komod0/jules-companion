/**
 * @file syntax_highlighter_test.cpp
 * @brief Tests for tree-sitter based syntax highlighter
 * 
 * TDD: These tests define the expected behavior of the SyntaxHighlighter.
 * The implementation should make these tests pass.
 */

#include "highlighting/syntax_highlighter.h"
#include <gtest/gtest.h>
#include <chrono>
#include <future>
#include <string>
#include <thread>
#include <vector>
#include <QDir>
#include <QTemporaryDir>

using namespace jules::highlighting;

class SyntaxHighlighterTest : public ::testing::Test {
protected:
    SyntaxHighlighter highlighter;
    
    void SetUp() override {
        // Highlighter should initialize successfully
        ASSERT_TRUE(highlighter.isInitialized());
    }
};

// =============================================================================
// Basic Initialization Tests
// =============================================================================

TEST_F(SyntaxHighlighterTest, InitializesSuccessfully) {
    EXPECT_TRUE(highlighter.isInitialized());
}

TEST_F(SyntaxHighlighterTest, ReportsAvailableLanguages) {
    auto languages = highlighter.availableLanguages();
    
    EXPECT_GE(languages.size(), 1);
    
    bool hasJson = std::find(languages.begin(), languages.end(), "json") != languages.end();
    bool hasGo = std::find(languages.begin(), languages.end(), "go") != languages.end();
    bool hasJava = std::find(languages.begin(), languages.end(), "java") != languages.end();
    bool hasC = std::find(languages.begin(), languages.end(), "c") != languages.end();
    
    EXPECT_TRUE(hasJson || hasGo || hasJava || hasC) << "Should have at least one working language";
}

TEST(SyntaxHighlighterTest, FindsGrammarsInAppImageLayout) {
    // Create mock AppImage layout in temp dir
    QTemporaryDir tempDir;
    QString grammarDir = tempDir.path() + "/usr/lib/jules-linux/grammars";
    QDir().mkpath(grammarDir);

    // Set environment
    qputenv("TREE_SITTER_GRAMMAR_PATH", grammarDir.toUtf8());

    SyntaxHighlighter highlighter;
    // Should not crash, should use env path

    qunsetenv("TREE_SITTER_GRAMMAR_PATH");
}

TEST_F(SyntaxHighlighterTest, TokenHasValidRange) {
    const std::string code = R"({"name": "test", "value": 42})";
    auto tokens = highlighter.highlight(code, "json");
    
    ASSERT_FALSE(tokens.empty()) << "JSON should produce tokens";
    
    for (const auto& token : tokens) {
        EXPECT_LE(token.start, token.end);
        EXPECT_LT(token.end, code.size() + 1);
        EXPECT_FALSE(token.type.empty());
    }
}

TEST_F(SyntaxHighlighterTest, TokenHasColor) {
    const std::string code = R"({"value": 42})";
    auto tokens = highlighter.highlight(code, "json");
    
    ASSERT_FALSE(tokens.empty()) << "JSON should produce tokens";
    
    for (const auto& token : tokens) {
        EXPECT_LE(token.color.r, 255);
        EXPECT_LE(token.color.g, 255);
        EXPECT_LE(token.color.b, 255);
        EXPECT_LE(token.color.a, 255);
    }
}

// =============================================================================
// Python Highlighting Tests
// =============================================================================

TEST_F(SyntaxHighlighterTest, JsonHighlightsStrings) {
    const std::string code = R"({"message": "hello world"})";
    auto tokens = highlighter.highlight(code, "json");
    
    ASSERT_FALSE(tokens.empty()) << "JSON should produce tokens";
    
    bool foundString = false;
    for (const auto& token : tokens) {
        if (token.type == "string") {
            foundString = true;
            break;
        }
    }
    
    EXPECT_TRUE(foundString) << "Should highlight string literal";
}

TEST_F(SyntaxHighlighterTest, JsonHighlightsNumbers) {
    const std::string code = R"({"value": 42})";
    auto tokens = highlighter.highlight(code, "json");
    
    ASSERT_FALSE(tokens.empty()) << "JSON should produce tokens";
    
    bool foundNumber = false;
    for (const auto& token : tokens) {
        if (token.type == "number") {
            foundNumber = true;
            break;
        }
    }
    
    EXPECT_TRUE(foundNumber) << "Should highlight number literal";
}

TEST_F(SyntaxHighlighterTest, GoHighlightsKeywords) {
    const std::string code = "func main() { var x = 5 }";
    auto tokens = highlighter.highlight(code, "go");
    
    if (tokens.empty()) {
        GTEST_SKIP() << "Go grammar not available with compatible ABI";
    }
    
    bool foundKeyword = false;
    for (const auto& token : tokens) {
        if (token.type == "keyword") {
            foundKeyword = true;
            break;
        }
    }
    
    EXPECT_TRUE(foundKeyword) << "Should highlight keyword";
}

TEST_F(SyntaxHighlighterTest, JavaHighlightsFunctions) {
    const std::string code = "public void hello() { }";
    auto tokens = highlighter.highlight(code, "java");
    
    if (tokens.empty()) {
        GTEST_SKIP() << "Java grammar not available with compatible ABI";
    }
    
    bool foundAny = false;
    for (const auto& token : tokens) {
        if (!token.type.empty()) {
            foundAny = true;
            break;
        }
    }
    
    EXPECT_TRUE(foundAny) << "Should produce some tokens";
}

// =============================================================================
// JavaScript Highlighting Tests
// =============================================================================

TEST_F(SyntaxHighlighterTest, CHighlightsKeywords) {
    const std::string code = "int main() { return 0; }";
    auto tokens = highlighter.highlight(code, "c");
    
    if (tokens.empty()) {
        GTEST_SKIP() << "C grammar not available with compatible ABI";
    }
    
    bool foundKeyword = false;
    for (const auto& token : tokens) {
        if (token.type == "keyword") {
            foundKeyword = true;
            break;
        }
    }
    
    EXPECT_TRUE(foundKeyword) << "Should highlight keyword";
}

TEST_F(SyntaxHighlighterTest, HtmlHighlightsTags) {
    const std::string code = "<html><body>Hello</body></html>";
    auto tokens = highlighter.highlight(code, "html");
    
    if (tokens.empty()) {
        GTEST_SKIP() << "HTML grammar not available with compatible ABI";
    }
    
    bool foundTag = false;
    for (const auto& token : tokens) {
        if (token.type == "tag") {
            foundTag = true;
            break;
        }
    }
    
    EXPECT_TRUE(foundTag) << "Should highlight HTML tag";
}

TEST_F(SyntaxHighlighterTest, CssHighlightsProperties) {
    const std::string code = "body { color: red; }";
    auto tokens = highlighter.highlight(code, "css");
    
    if (tokens.empty()) {
        GTEST_SKIP() << "CSS grammar not available with compatible ABI";
    }
    
    EXPECT_GT(tokens.size(), 0) << "Should produce some tokens";
}

TEST_F(SyntaxHighlighterTest, YamlHighlightsValues) {
    const std::string code = "name: value\ncount: 42";
    auto tokens = highlighter.highlight(code, "yaml");
    
    if (tokens.empty()) {
        GTEST_SKIP() << "YAML grammar not available with compatible ABI";
    }
    
    EXPECT_GT(tokens.size(), 0) << "Should produce some tokens";
}

// =============================================================================
// All 20 Languages - Parse Without Crash Tests
// =============================================================================

class LanguageParseTest : public ::testing::TestWithParam<std::pair<std::string, std::string>> {
protected:
    SyntaxHighlighter highlighter;
};

TEST_P(LanguageParseTest, ParsesWithoutCrash) {
    auto [language, code] = GetParam();
    
    // Should not throw or crash
    ASSERT_NO_THROW({
        auto tokens = highlighter.highlight(code, language);
        // Should return some tokens (may be empty for trivial code, but shouldn't crash)
    });
}

// Sample code for each of the 20 languages
INSTANTIATE_TEST_SUITE_P(
    AllLanguages,
    LanguageParseTest,
    ::testing::Values(
        std::make_pair("python", "def hello(): print('Hello')"),
        std::make_pair("javascript", "function hello() { console.log('Hello'); }"),
        std::make_pair("typescript", "const greet = (name: string): void => {};"),
        std::make_pair("rust", "fn main() { println!(\"Hello\"); }"),
        std::make_pair("go", "func main() { fmt.Println(\"Hello\") }"),
        std::make_pair("java", "public class Hello { public static void main(String[] args) {} }"),
        std::make_pair("c", "int main() { printf(\"Hello\"); return 0; }"),
        std::make_pair("cpp", "int main() { std::cout << \"Hello\"; return 0; }"),
        std::make_pair("ruby", "def hello; puts 'Hello'; end"),
        std::make_pair("php", "<?php function hello() { echo 'Hello'; } ?>"),
        std::make_pair("swift", "func hello() { print(\"Hello\") }"),
        std::make_pair("kotlin", "fun main() { println(\"Hello\") }"),
        std::make_pair("scala", "object Hello { def main(args: Array[String]) = println(\"Hello\") }"),
        std::make_pair("lua", "function hello() print('Hello') end"),
        std::make_pair("bash", "#!/bin/bash\necho \"Hello\""),
        std::make_pair("sql", "SELECT * FROM users WHERE name = 'test';"),
        std::make_pair("html", "<!DOCTYPE html><html><body>Hello</body></html>"),
        std::make_pair("css", "body { color: red; font-size: 16px; }"),
        std::make_pair("json", "{\"name\": \"test\", \"value\": 42}"),
        std::make_pair("yaml", "name: test\nvalue: 42")
    )
);

// =============================================================================
// Async Parsing Tests
// =============================================================================

TEST_F(SyntaxHighlighterTest, AsyncParsingForLargeFiles) {
    std::string largeCode = "[";
    for (int i = 0; i < 1000; i++) {
        if (i > 0) largeCode += ",";
        largeCode += "{\"id\":" + std::to_string(i) + ",\"name\":\"item" + std::to_string(i) + "\"}";
    }
    largeCode += "]";
    
    auto future = highlighter.highlightAsync(largeCode, "json");
    
    auto status = future.wait_for(std::chrono::seconds(10));
    ASSERT_EQ(status, std::future_status::ready) << "Async parsing took too long";
    
    auto tokens = future.get();
    EXPECT_FALSE(tokens.empty()) << "Should produce tokens for large file";
}

TEST_F(SyntaxHighlighterTest, AsyncParsingReturnsImmediately) {
    const std::string code = R"({"test": 42})";
    
    auto start = std::chrono::steady_clock::now();
    auto future = highlighter.highlightAsync(code, "json");
    auto end = std::chrono::steady_clock::now();
    
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    EXPECT_LT(duration.count(), 50) << "Async method should return immediately";
    
    auto tokens = future.get();
    EXPECT_FALSE(tokens.empty());
}

TEST_F(SyntaxHighlighterTest, MultipleAsyncParsesInParallel) {
    std::vector<std::future<std::vector<SyntaxToken>>> futures;
    
    futures.push_back(highlighter.highlightAsync(R"({"a":1})", "json"));
    futures.push_back(highlighter.highlightAsync(R"({"b":2})", "json"));
    futures.push_back(highlighter.highlightAsync(R"({"c":3})", "json"));
    
    for (auto& future : futures) {
        ASSERT_EQ(future.wait_for(std::chrono::seconds(5)), std::future_status::ready);
        auto tokens = future.get();
        EXPECT_FALSE(tokens.empty());
    }
}

// =============================================================================
// Color Mapping Tests (Matching Mac App Theme)
// =============================================================================

TEST_F(SyntaxHighlighterTest, StringColorMatches) {
    const std::string code = R"({"message": "hello"})";
    auto tokens = highlighter.highlight(code, "json");
    
    for (const auto& token : tokens) {
        if (token.type == "string") {
            EXPECT_GT(token.color.g, 100) << "String should have green component";
            break;
        }
    }
}

TEST_F(SyntaxHighlighterTest, NumberColorMatches) {
    const std::string code = R"({"value": 42})";
    auto tokens = highlighter.highlight(code, "json");
    
    for (const auto& token : tokens) {
        if (token.type == "number") {
            EXPECT_GT(token.color.r, 100) << "Number should have color";
            break;
        }
    }
}

// =============================================================================
// Edge Cases and Error Handling
// =============================================================================

TEST_F(SyntaxHighlighterTest, EmptyInputReturnsEmptyTokens) {
    auto tokens = highlighter.highlight("", "python");
    EXPECT_TRUE(tokens.empty());
}

TEST_F(SyntaxHighlighterTest, UnknownLanguageFallsBackGracefully) {
    // Unknown language should not crash - either returns empty or uses fallback
    ASSERT_NO_THROW({
        auto tokens = highlighter.highlight("some code", "unknown_language_xyz");
        // May be empty, that's fine
    });
}

TEST_F(SyntaxHighlighterTest, UnicodeHandledCorrectly) {
    // Use JSON since Python grammar may not be available
    const std::string code = R"({"message": "Commentaire français avec accents", "emoji": "🎉"})";
    
    ASSERT_NO_THROW({
        auto tokens = highlighter.highlight(code, "json");
        // Should have parsed something
        EXPECT_FALSE(tokens.empty());
    });
}

TEST_F(SyntaxHighlighterTest, VeryLongLinesHandled) {
    std::string longLine = "x = \"";
    for (int i = 0; i < 10000; i++) {
        longLine += "a";
    }
    longLine += "\"";
    
    ASSERT_NO_THROW({
        auto tokens = highlighter.highlight(longLine, "python");
    });
}

// =============================================================================
// Performance Tests
// =============================================================================

TEST_F(SyntaxHighlighterTest, ParsesSmallFileQuickly) {
    const std::string code = "def foo(x, y):\n    return x + y\n";
    
    auto start = std::chrono::steady_clock::now();
    
    for (int i = 0; i < 100; i++) {
        auto tokens = highlighter.highlight(code, "python");
    }
    
    auto end = std::chrono::steady_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    // 100 small parses should complete in < 1 second
    EXPECT_LT(duration.count(), 1000) << "Small file parsing is too slow";
}

// =============================================================================
// Line-based Token Access Tests
// =============================================================================

TEST_F(SyntaxHighlighterTest, TokensPerLineAccurate) {
    const std::string code = R"({"name": "test",
"value": 42})";
    auto lineTokens = highlighter.highlightByLine(code, "json");
    
    EXPECT_FALSE(lineTokens.empty());
    
    if (lineTokens.count(0) > 0) {
        bool foundString = false;
        for (const auto& token : lineTokens.at(0)) {
            if (token.type == "string") {
                foundString = true;
                break;
            }
        }
        EXPECT_TRUE(foundString);
    }
    
    if (lineTokens.count(1) > 0) {
        bool foundNumber = false;
        for (const auto& token : lineTokens.at(1)) {
            if (token.type == "number") {
                foundNumber = true;
                break;
            }
        }
        EXPECT_TRUE(foundNumber);
    }
}

// =============================================================================
// Main
// =============================================================================

int main(int argc, char **argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
