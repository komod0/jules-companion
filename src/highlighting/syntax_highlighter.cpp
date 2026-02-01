#include "highlighting/syntax_highlighter.h"
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <algorithm>
#include <dlfcn.h>
#include <filesystem>
#include <mutex>
#include <thread>
#include <tree_sitter/api.h>
#include <unordered_map>

namespace jules::highlighting {

namespace {

    QString findGrammarPath() {
      // 1. Check environment variable (AppImage sets this in AppRun)
      QString envPath = qEnvironmentVariable("TREE_SITTER_GRAMMAR_PATH");
      if (!envPath.isEmpty() && QDir(envPath).exists()) {
        qDebug() << "Using grammar path from env:" << envPath;
        return envPath;
      }

      // 2. Check relative to executable (installed layout)
      QString exeDir = QCoreApplication::applicationDirPath();

      // AppImage: /tmp/.mount_xxx/usr/bin ->
      // /tmp/.mount_xxx/usr/lib/jules-linux/grammars
      QString appImagePath = exeDir + "/../lib/jules-linux/grammars";
      if (QDir(appImagePath).exists()) {
        qDebug() << "Using grammar path (AppImage):"
                 << QDir(appImagePath).canonicalPath();
        return QDir(appImagePath).canonicalPath();
      }

      // 3. Check build directory (development)
      QString buildPath = QDir::currentPath() + "/grammars";
      if (QDir(buildPath).exists()) {
        qDebug() << "Using grammar path (build):" << buildPath;
        return buildPath;
      }

      // 4. Fallback to relative path
      qWarning() << "Grammar path not found, using fallback";
      return QStringLiteral("./grammars");
    }
    
struct LanguageInfo {
    std::string name;
    std::string grammarLib;
    std::string treeSitterFuncName;
    TSLanguage* (*languageFunc)() = nullptr;
    void* dlHandle = nullptr;
    TSQuery* highlightQuery = nullptr;
};

const std::unordered_map<std::string, Color> kSyntaxColors = {
    {"keyword",  Color(165, 143, 232, 255)},  // #A58FE8 - purple
    {"string",   Color(109, 220, 126, 255)},  // #6DDC7E - green
    {"comment",  Color(114, 193, 247, 255)},  // #72C1F7 - blue
    {"function", Color(237, 114, 241, 255)},  // #ED72F1 - pink
    {"type",     Color(237, 114, 241, 255)},  // #ED72F1 - pink
    {"variable", Color(255, 229, 229, 255)},  // #FFE5E5 - light pink
    {"number",   Color(245, 198, 134, 255)},  // #F5C686 - orange
    {"operator", Color(245, 198, 134, 255)},  // #F5C686 - orange
    {"tag",      Color(114, 193, 247, 255)},  // #72C1F7 - blue
    {"regexp",   Color(109, 220, 126, 255)},  // #6DDC7E - green
    {"special",  Color(245, 198, 134, 255)},  // #F5C686 - orange
};

std::string getHighlightQuery(const std::string& lang) {
    static const std::unordered_map<std::string, std::string> queries = {
        {"python", R"(
(comment) @comment
(string) @string
(integer) @number
(float) @number
(identifier) @variable
(function_definition name: (identifier) @function)
(call function: (identifier) @function)
(class_definition name: (identifier) @type)
"def" @keyword
"class" @keyword
"return" @keyword
"if" @keyword
"elif" @keyword
"else" @keyword
"for" @keyword
"while" @keyword
"import" @keyword
"from" @keyword
"as" @keyword
"try" @keyword
"except" @keyword
"finally" @keyword
"with" @keyword
"async" @keyword
"await" @keyword
"pass" @keyword
"break" @keyword
"continue" @keyword
"and" @keyword
"or" @keyword
"not" @keyword
"in" @keyword
"is" @keyword
"True" @keyword
"False" @keyword
"None" @keyword
)"},
        {"javascript", R"(
(comment) @comment
(string) @string
(template_string) @string
(number) @number
(identifier) @variable
(function_declaration name: (identifier) @function)
(call_expression function: (identifier) @function)
(class_declaration name: (identifier) @type)
"function" @keyword
"class" @keyword
"return" @keyword
"if" @keyword
"else" @keyword
"for" @keyword
"while" @keyword
"const" @keyword
"let" @keyword
"var" @keyword
"async" @keyword
"await" @keyword
"import" @keyword
"export" @keyword
"from" @keyword
"try" @keyword
"catch" @keyword
"finally" @keyword
"throw" @keyword
"new" @keyword
"this" @keyword
"true" @keyword
"false" @keyword
"null" @keyword
)"},
        {"typescript", R"(
(comment) @comment
(string) @string
(template_string) @string
(number) @number
(identifier) @variable
(function_declaration name: (identifier) @function)
(call_expression function: (identifier) @function)
(class_declaration name: (identifier) @type)
(interface_declaration name: (type_identifier) @type)
(type_identifier) @type
"function" @keyword
"class" @keyword
"interface" @keyword
"type" @keyword
"return" @keyword
"if" @keyword
"else" @keyword
"for" @keyword
"while" @keyword
"const" @keyword
"let" @keyword
"var" @keyword
"async" @keyword
"await" @keyword
"import" @keyword
"export" @keyword
"from" @keyword
"try" @keyword
"catch" @keyword
"finally" @keyword
"throw" @keyword
"new" @keyword
"this" @keyword
"public" @keyword
"private" @keyword
"protected" @keyword
"static" @keyword
"true" @keyword
"false" @keyword
"null" @keyword
)"},
        {"rust", R"(
(line_comment) @comment
(block_comment) @comment
(string_literal) @string
(char_literal) @string
(integer_literal) @number
(float_literal) @number
(boolean_literal) @number
(identifier) @variable
(function_item name: (identifier) @function)
(call_expression function: (identifier) @function)
(type_identifier) @type
(primitive_type) @type
"fn" @keyword
"let" @keyword
"mut" @keyword
"const" @keyword
"struct" @keyword
"enum" @keyword
"trait" @keyword
"impl" @keyword
"type" @keyword
"mod" @keyword
"use" @keyword
"pub" @keyword
"if" @keyword
"else" @keyword
"match" @keyword
"loop" @keyword
"while" @keyword
"for" @keyword
"in" @keyword
"break" @keyword
"continue" @keyword
"return" @keyword
"async" @keyword
"await" @keyword
"true" @keyword
"false" @keyword
)"},
        {"go", R"(
(comment) @comment
(raw_string_literal) @string
(interpreted_string_literal) @string
(int_literal) @number
(float_literal) @number
(identifier) @variable
(function_declaration name: (identifier) @function)
(call_expression function: (identifier) @function)
(type_identifier) @type
"func" @keyword
"var" @keyword
"const" @keyword
"type" @keyword
"struct" @keyword
"interface" @keyword
"package" @keyword
"import" @keyword
"if" @keyword
"else" @keyword
"for" @keyword
"range" @keyword
"switch" @keyword
"case" @keyword
"default" @keyword
"return" @keyword
"go" @keyword
"defer" @keyword
"break" @keyword
"continue" @keyword
"true" @keyword
"false" @keyword
"nil" @keyword
)"},
        {"java", R"(
            (line_comment) @comment
            (block_comment) @comment
            (string_literal) @string
            (character_literal) @string
            (decimal_integer_literal) @number
            (decimal_floating_point_literal) @number
            (hex_integer_literal) @number
            (true) @number
            (false) @number
            (null_literal) @number
            (identifier) @variable
            (method_declaration name: (identifier) @function)
            (method_invocation name: (identifier) @function)
            (class_declaration name: (identifier) @type)
            (interface_declaration name: (identifier) @type)
            (type_identifier) @type
            ["class" "interface" "enum" "extends" "implements" "public"
             "private" "protected" "static" "final" "abstract" "synchronized"
             "volatile" "native" "transient" "if" "else" "switch" "case"
             "default" "for" "while" "do" "break" "continue" "return" "throw"
             "throws" "try" "catch" "finally" "new" "this" "super" "instanceof"
             "import" "package" "void" "null" "true" "false"] @keyword
        )"},
        {"c", R"(
            (comment) @comment
            (string_literal) @string
            (char_literal) @string
            (number_literal) @number
            (true) @number
            (false) @number
            (null) @number
            (identifier) @variable
            (function_definition declarator: (function_declarator declarator: (identifier) @function))
            (call_expression function: (identifier) @function)
            (type_identifier) @type
            (primitive_type) @type
            ["if" "else" "switch" "case" "default" "for" "while" "do" "break"
             "continue" "return" "goto" "struct" "union" "enum" "typedef"
             "const" "static" "extern" "inline" "volatile" "register" "sizeof"
             "void" "int" "char" "float" "double" "long" "short" "signed"
             "unsigned" "NULL" "auto"] @keyword
        )"},
        {"cpp", R"(
            (comment) @comment
            (string_literal) @string
            (raw_string_literal) @string
            (char_literal) @string
            (number_literal) @number
            (true) @number
            (false) @number
            (null) @number
            (nullptr) @number
            (identifier) @variable
            (function_definition declarator: (function_declarator declarator: (identifier) @function))
            (call_expression function: (identifier) @function)
            (type_identifier) @type
            (primitive_type) @type
            ["if" "else" "switch" "case" "default" "for" "while" "do" "break"
             "continue" "return" "goto" "struct" "union" "enum" "typedef"
             "const" "static" "extern" "inline" "volatile" "register" "sizeof"
             "void" "int" "char" "float" "double" "long" "short" "signed"
             "unsigned" "class" "public" "private" "protected" "virtual"
             "override" "final" "template" "typename" "namespace" "using"
             "new" "delete" "nullptr" "this" "auto" "constexpr" "noexcept"
             "explicit" "mutable" "friend" "operator" "throw" "try" "catch"
             "true" "false"] @keyword
        )"},
        {"ruby", R"(
            (comment) @comment
            (string) @string
            (symbol) @string
            (heredoc_body) @string
            (integer) @number
            (float) @number
            (true) @number
            (false) @number
            (nil) @number
            (identifier) @variable
            (method name: (identifier) @function)
            (call method: (identifier) @function)
            (class name: (constant) @type)
            (constant) @type
            ["def" "end" "class" "module" "if" "elsif" "else" "unless" "case"
             "when" "while" "until" "for" "do" "begin" "rescue" "ensure"
             "raise" "return" "break" "next" "redo" "retry" "yield" "self"
             "super" "true" "false" "nil" "and" "or" "not" "in" "then"
             "attr_reader" "attr_writer" "attr_accessor" "private" "protected"
             "public" "require" "require_relative" "include" "extend"] @keyword
        )"},
        {"php", R"(
            (comment) @comment
            (string) @string
            (heredoc) @string
            (integer) @number
            (float) @number
            (boolean) @number
            (null) @number
            (variable_name) @variable
            (function_definition name: (name) @function)
            (function_call_expression function: (name) @function)
            (method_declaration name: (name) @function)
            (class_declaration name: (name) @type)
            (interface_declaration name: (name) @type)
            ["function" "class" "interface" "trait" "extends" "implements"
             "public" "private" "protected" "static" "final" "abstract"
             "const" "new" "clone" "if" "elseif" "else" "switch" "case"
             "default" "for" "foreach" "while" "do" "break" "continue"
             "return" "try" "catch" "finally" "throw" "namespace" "use"
             "echo" "print" "require" "require_once" "include" "include_once"
             "true" "false" "null" "global" "array" "instanceof" "as"] @keyword
        )"},
        {"swift", R"(
            (comment) @comment
            (multiline_comment) @comment
            (line_str_text) @string
            (multi_line_str_text) @string
            (integer_literal) @number
            (real_literal) @number
            (boolean_literal) @number
            (nil) @number
            (simple_identifier) @variable
            (function_declaration (simple_identifier) @function)
            (call_expression (simple_identifier) @function)
            (class_declaration (type_identifier) @type)
            (struct_declaration (type_identifier) @type)
            (protocol_declaration (type_identifier) @type)
            (type_identifier) @type
            ["func" "class" "struct" "enum" "protocol" "extension" "init"
             "deinit" "var" "let" "static" "private" "fileprivate" "internal"
             "public" "open" "if" "else" "guard" "switch" "case" "default"
             "for" "while" "repeat" "in" "return" "break" "continue" "import"
             "typealias" "self" "Self" "super" "nil" "true" "false" "try"
             "catch" "throw" "throws" "async" "await" "override" "final"
             "mutating" "nonmutating" "lazy" "weak" "unowned" "where" "is"
             "as" "inout" "associatedtype" "subscript" "convenience" "required"
             "dynamic" "optional"] @keyword
        )"},
        {"kotlin", R"(
            (line_comment) @comment
            (multiline_comment) @comment
            (line_string_literal) @string
            (multi_line_string_literal) @string
            (character_literal) @string
            (integer_literal) @number
            (long_literal) @number
            (real_literal) @number
            (boolean_literal) @number
            (null_literal) @number
            (simple_identifier) @variable
            (function_declaration (simple_identifier) @function)
            (call_expression (simple_identifier) @function)
            (class_declaration (type_identifier) @type)
            (object_declaration (type_identifier) @type)
            (type_identifier) @type
            ["fun" "val" "var" "class" "object" "interface" "enum" "sealed"
             "data" "inner" "companion" "init" "constructor" "if" "else"
             "when" "for" "while" "do" "break" "continue" "return" "throw"
             "try" "catch" "finally" "is" "as" "in" "out" "package" "import"
             "public" "private" "protected" "internal" "open" "final"
             "override" "abstract" "suspend" "inline" "crossinline" "noinline"
             "reified" "operator" "infix" "tailrec" "external" "annotation"
             "true" "false" "null" "this" "super" "typeof" "where" "by"
             "get" "set" "lateinit" "vararg"] @keyword
        )"},
        {"scala", R"(
            (comment) @comment
            (block_comment) @comment
            (string) @string
            (interpolated_string) @string
            (integer_literal) @number
            (floating_point_literal) @number
            (boolean_literal) @number
            (null_literal) @number
            (identifier) @variable
            (function_definition name: (identifier) @function)
            (call_expression function: (identifier) @function)
            (class_definition name: (identifier) @type)
            (object_definition name: (identifier) @type)
            (trait_definition name: (identifier) @type)
            (type_identifier) @type
            ["def" "val" "var" "class" "object" "trait" "extends" "with"
             "abstract" "final" "sealed" "override" "implicit" "lazy" "case"
             "if" "else" "match" "for" "while" "do" "return" "throw" "try"
             "catch" "finally" "new" "this" "super" "type" "package" "import"
             "private" "protected" "public" "true" "false" "null" "yield"
             "forSome" "given" "using" "then" "end" "enum" "export"
             "extension" "inline" "opaque" "transparent"] @keyword
        )"},
        {"lua", R"(
            (comment) @comment
            (string) @string
            (number) @number
            (true) @number
            (false) @number
            (nil) @number
            (identifier) @variable
            (function_declaration name: (identifier) @function)
            (function_call name: (identifier) @function)
            ["function" "end" "local" "return" "if" "then" "else" "elseif"
             "for" "while" "do" "repeat" "until" "break" "in" "and" "or"
             "not" "true" "false" "nil" "goto" "require"] @keyword
        )"},
        {"bash", R"(
            (comment) @comment
            (string) @string
            (raw_string) @string
            (heredoc_body) @string
            (number) @number
            (variable_name) @variable
            (word) @variable
            (function_definition name: (word) @function)
            (command_name) @function
            ["if" "then" "else" "elif" "fi" "case" "esac" "for" "while"
             "until" "do" "done" "in" "function" "return" "exit" "break"
             "continue" "local" "export" "readonly" "declare" "typeset"
             "unset" "shift" "true" "false" "source" "alias"] @keyword
        )"},
        {"sql", R"(
            (comment) @comment
            (literal) @string
            (number) @number
            (NULL) @number
            (TRUE) @number
            (FALSE) @number
            (identifier) @variable
            (function_call name: (identifier) @function)
            ((identifier) @keyword
             (#match? @keyword "(?i)^(SELECT|FROM|WHERE|AND|OR|NOT|IN|LIKE|BETWEEN|IS|NULL|AS|ORDER|BY|ASC|DESC|LIMIT|OFFSET|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|ALTER|DROP|INDEX|VIEW|JOIN|LEFT|RIGHT|INNER|OUTER|ON|GROUP|HAVING|UNION|ALL|DISTINCT|COUNT|SUM|AVG|MAX|MIN|CASE|WHEN|THEN|ELSE|END|TRUE|FALSE|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|UNIQUE|DEFAULT|NOT|CHECK|EXISTS|ANY|SOME)$"))
        )"},
        {"html", R"(
            (comment) @comment
            (attribute_value) @string
            (quoted_attribute_value) @string
            (text) @variable
            (tag_name) @tag
            (attribute_name) @variable
            (doctype) @keyword
        )"},
        {"css", R"(
            (comment) @comment
            (string_value) @string
            (color_value) @string
            (integer_value) @number
            (float_value) @number
            (plain_value) @variable
            (property_name) @variable
            (tag_name) @tag
            (class_name) @type
            (id_name) @type
            (pseudo_class_selector (class_name) @function)
            (pseudo_element_selector (tag_name) @function)
            (function_name) @function
            ["@media" "@import" "@keyframes" "@font-face" "@supports"
             "@charset" "@namespace" "@page" "@property" "important"] @keyword
        )"},
        {"json", R"(
            (string) @string
            (number) @number
            (true) @number
            (false) @number
            (null) @number
            (pair key: (string) @variable)
        )"},
        {"yaml", R"(
            (comment) @comment
            (string_scalar) @string
            (single_quote_string_scalar) @string
            (double_quote_string_scalar) @string
            (integer_scalar) @number
            (float_scalar) @number
            (boolean_scalar) @number
            (null_scalar) @number
            (anchor) @variable
            (alias) @variable
            (block_mapping_pair key: (_) @variable)
            (flow_mapping key: (_) @variable)
        )"},
    };
    
    auto it = queries.find(lang);
    if (it != queries.end()) {
        return it->second;
    }
    return "";
}

std::string mapCaptureToType(const std::string& captureName) {
    static const std::unordered_map<std::string, std::string> mapping = {
        {"keyword", "keyword"},
        {"keyword.control", "keyword"},
        {"keyword.function", "keyword"},
        {"keyword.return", "keyword"},
        {"keyword.import", "keyword"},
        {"keyword.operator", "operator"},
        {"string", "string"},
        {"string.special", "string"},
        {"string.escape", "string"},
        {"comment", "comment"},
        {"comment.line", "comment"},
        {"comment.block", "comment"},
        {"function", "function"},
        {"function.call", "function"},
        {"function.method", "function"},
        {"function.builtin", "function"},
        {"type", "type"},
        {"type.builtin", "type"},
        {"type.definition", "type"},
        {"variable", "variable"},
        {"variable.builtin", "variable"},
        {"variable.parameter", "variable"},
        {"number", "number"},
        {"constant", "number"},
        {"constant.numeric", "number"},
        {"constant.boolean", "number"},
        {"operator", "operator"},
        {"punctuation", "operator"},
        {"tag", "tag"},
        {"attribute", "variable"},
        {"property", "variable"},
        {"regexp", "regexp"},
        {"special", "special"},
    };
    
    auto it = mapping.find(captureName);
    if (it != mapping.end()) {
        return it->second;
    }
    
    for (const auto& [pattern, type] : mapping) {
        if (captureName.find(pattern) == 0 || pattern.find(captureName) == 0) {
            return type;
        }
    }
    
    return "variable";
}

}  // namespace

class SyntaxHighlighter::Impl {
public:
    Impl() : m_initialized(false) {
        initialize();
        loadLanguages();
    }
    
    ~Impl() {
        for (auto& [name, info] : m_languages) {
            if (info.highlightQuery) {
                ts_query_delete(info.highlightQuery);
            }
            if (info.dlHandle) {
                dlclose(info.dlHandle);
            }
        }
        if (m_parser) {
            ts_parser_delete(m_parser);
        }
    }
    
    bool isInitialized() const {
        return m_initialized;
    }
    
    std::vector<std::string> availableLanguages() const {
        std::vector<std::string> result;
        result.reserve(m_languages.size());
        for (const auto& [name, info] : m_languages) {
            if (info.languageFunc) {
                result.push_back(name);
            }
        }
        return result;
    }
    
    std::vector<SyntaxToken> highlight(const std::string& code, const std::string& language) const {
        std::vector<SyntaxToken> tokens;
        
        if (code.empty()) {
            return tokens;
        }
        
        std::string lang = normalizeLanguageName(language);
        auto it = m_languages.find(lang);
        if (it == m_languages.end() || !it->second.languageFunc) {
            return tokens;
        }
        
        const LanguageInfo& info = it->second;
        
        std::lock_guard<std::mutex> lock(m_parserMutex);
        
        TSLanguage* tsLang = info.languageFunc();
        if (!tsLang) {
            return tokens;
        }
        
        ts_parser_set_language(m_parser, tsLang);
        
        TSTree* tree = ts_parser_parse_string(m_parser, nullptr, code.c_str(), static_cast<uint32_t>(code.size()));
        if (!tree) {
            return tokens;
        }
        
        TSQuery* query = info.highlightQuery;
        if (!query) {
            std::string queryStr = getHighlightQuery(lang);
            if (!queryStr.empty()) {
                uint32_t errorOffset;
                TSQueryError errorType;
                query = ts_query_new(tsLang, queryStr.c_str(), 
                    static_cast<uint32_t>(queryStr.size()), &errorOffset, &errorType);
                if (query) {
                    const_cast<LanguageInfo&>(info).highlightQuery = query;
                }
            }
        }
        
        if (query) {
            TSQueryCursor* cursor = ts_query_cursor_new();
            TSNode rootNode = ts_tree_root_node(tree);
            ts_query_cursor_exec(cursor, query, rootNode);
            
            TSQueryMatch match;
            while (ts_query_cursor_next_match(cursor, &match)) {
                for (uint16_t i = 0; i < match.capture_count; i++) {
                    TSQueryCapture capture = match.captures[i];
                    uint32_t captureNameLen;
                    const char* captureName = ts_query_capture_name_for_id(query, capture.index, &captureNameLen);
                    
                    TSNode node = capture.node;
                    uint32_t startByte = ts_node_start_byte(node);
                    uint32_t endByte = ts_node_end_byte(node);
                    
                    std::string captureStr(captureName, captureNameLen);
                    std::string tokenType = mapCaptureToType(captureStr);
                    
                    Color color = getColorForType(tokenType);
                    
                    SyntaxToken token;
                    token.start = startByte;
                    token.end = endByte;
                    token.type = tokenType;
                    token.color = color;
                    
                    tokens.push_back(token);
                }
            }
            
            ts_query_cursor_delete(cursor);
        }
        
        ts_tree_delete(tree);
        
        std::sort(tokens.begin(), tokens.end(), 
            [](const SyntaxToken& a, const SyntaxToken& b) {
                return a.start < b.start;
            });
        
        return tokens;
    }
    
    std::map<size_t, std::vector<SyntaxToken>> highlightByLine(
        const std::string& code, const std::string& language) const 
    {
        std::map<size_t, std::vector<SyntaxToken>> result;
        
        std::vector<size_t> lineStarts;
        lineStarts.push_back(0);
        for (size_t i = 0; i < code.size(); i++) {
            if (code[i] == '\n') {
                lineStarts.push_back(i + 1);
            }
        }
        
        auto tokens = highlight(code, language);
        
        for (const auto& token : tokens) {
            size_t line = std::upper_bound(lineStarts.begin(), lineStarts.end(), token.start) 
                         - lineStarts.begin() - 1;
            
            size_t lineStart = lineStarts[line];
            
            SyntaxToken lineToken = token;
            lineToken.start = token.start - lineStart;
            lineToken.end = token.end - lineStart;
            
            result[line].push_back(lineToken);
        }
        
        return result;
    }
    
private:
    void initialize() { m_grammarPath = findGrammarPath(); }
    void loadLanguages() {
        m_parser = ts_parser_new();
        if (!m_parser) {
            return;
        }
        
        const std::vector<std::tuple<std::string, std::string, std::string>> languageSpecs = {
            {"python", "libtree-sitter-python.so", "tree_sitter_python"},
            {"javascript", "libtree-sitter-javascript.so", "tree_sitter_javascript"},
            {"typescript", "libtree-sitter-typescript.so", "tree_sitter_typescript"},
            {"rust", "libtree-sitter-rust.so", "tree_sitter_rust"},
            {"go", "libtree-sitter-go.so", "tree_sitter_go"},
            {"java", "libtree-sitter-java.so", "tree_sitter_java"},
            {"c", "libtree-sitter-c.so", "tree_sitter_c"},
            {"cpp", "libtree-sitter-cpp.so", "tree_sitter_cpp"},
            {"ruby", "libtree-sitter-ruby.so", "tree_sitter_ruby"},
            {"php", "libtree-sitter-php.so", "tree_sitter_php"},
            {"swift", "libtree-sitter-swift.so", "tree_sitter_swift"},
            {"kotlin", "libtree-sitter-kotlin.so", "tree_sitter_kotlin"},
            {"scala", "libtree-sitter-scala.so", "tree_sitter_scala"},
            {"lua", "libtree-sitter-lua.so", "tree_sitter_lua"},
            {"bash", "libtree-sitter-bash.so", "tree_sitter_bash"},
            {"sql", "libtree-sitter-sql.so", "tree_sitter_sql"},
            {"html", "libtree-sitter-html.so", "tree_sitter_html"},
            {"css", "libtree-sitter-css.so", "tree_sitter_css"},
            {"json", "libtree-sitter-json.so", "tree_sitter_json"},
            {"yaml", "libtree-sitter-yaml.so", "tree_sitter_yaml"},
        };
        
        for (const auto& [name, libName, funcName] : languageSpecs) {
            LanguageInfo info;
            info.name = name;
            info.grammarLib = libName;
            info.treeSitterFuncName = funcName;
            
            QString fullPath = m_grammarPath + "/" + QString::fromStdString(libName);
            void* handle = dlopen(fullPath.toStdString().c_str(), RTLD_LAZY);
            if (handle) {
                auto func = reinterpret_cast<TSLanguage* (*)()>(dlsym(handle, funcName.c_str()));
                if (func) {
                    info.dlHandle = handle;
                    info.languageFunc = func;
                    m_initialized = true;
                } else {
                    dlclose(handle);
                }
            }
            
            m_languages[name] = info;
        }
    }
    
    std::string normalizeLanguageName(const std::string& name) const {
        std::string lower = name;
        std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
        
        static const std::unordered_map<std::string, std::string> aliases = {
            {"py", "python"},
            {"js", "javascript"},
            {"ts", "typescript"},
            {"rs", "rust"},
            {"golang", "go"},
            {"c++", "cpp"},
            {"cxx", "cpp"},
            {"rb", "ruby"},
            {"sh", "bash"},
            {"shell", "bash"},
            {"zsh", "bash"},
            {"yml", "yaml"},
            {"kt", "kotlin"},
        };
        
        auto it = aliases.find(lower);
        if (it != aliases.end()) {
            return it->second;
        }
        return lower;
    }
    
    Color getColorForType(const std::string& type) const {
        auto it = kSyntaxColors.find(type);
        if (it != kSyntaxColors.end()) {
            return it->second;
        }
        return Color(229, 229, 229, 255);
    }
    
    TSParser* m_parser = nullptr;
    std::unordered_map<std::string, LanguageInfo> m_languages;
    mutable std::mutex m_parserMutex;
    bool m_initialized;
    QString m_grammarPath;
};

Color Color::fromHex(const std::string& hex) {
    std::string h = hex;
    if (!h.empty() && h[0] == '#') {
        h = h.substr(1);
    }
    
    if (h.size() < 6) {
        return Color();
    }
    
    auto hexToInt = [](const std::string& s) -> uint8_t {
        return static_cast<uint8_t>(std::stoul(s, nullptr, 16));
    };
    
    uint8_t r = hexToInt(h.substr(0, 2));
    uint8_t g = hexToInt(h.substr(2, 2));
    uint8_t b = hexToInt(h.substr(4, 2));
    uint8_t a = (h.size() >= 8) ? hexToInt(h.substr(6, 2)) : 255;
    
    return Color(r, g, b, a);
}

SyntaxHighlighter::SyntaxHighlighter() : m_impl(std::make_unique<Impl>()) {}

SyntaxHighlighter::~SyntaxHighlighter() = default;

SyntaxHighlighter::SyntaxHighlighter(SyntaxHighlighter&&) noexcept = default;
SyntaxHighlighter& SyntaxHighlighter::operator=(SyntaxHighlighter&&) noexcept = default;

bool SyntaxHighlighter::isInitialized() const {
    return m_impl->isInitialized();
}

std::vector<std::string> SyntaxHighlighter::availableLanguages() const {
    return m_impl->availableLanguages();
}

std::vector<SyntaxToken> SyntaxHighlighter::highlight(
    const std::string& code, const std::string& language) const 
{
    return m_impl->highlight(code, language);
}

std::future<std::vector<SyntaxToken>> SyntaxHighlighter::highlightAsync(
    const std::string& code, const std::string& language) const 
{
    return std::async(std::launch::async, [this, code, language]() {
        return this->highlight(code, language);
    });
}

std::map<size_t, std::vector<SyntaxToken>> SyntaxHighlighter::highlightByLine(
    const std::string& code, const std::string& language) const 
{
    return m_impl->highlightByLine(code, language);
}

Color SyntaxHighlighter::colorForSyntaxType(SyntaxType type) {
    switch (type) {
        case SyntaxType::Keyword:  return Color(165, 143, 232, 255);
        case SyntaxType::String:   return Color(109, 220, 126, 255);
        case SyntaxType::Comment:  return Color(114, 193, 247, 255);
        case SyntaxType::Function: return Color(237, 114, 241, 255);
        case SyntaxType::Type:     return Color(237, 114, 241, 255);
        case SyntaxType::Variable: return Color(255, 229, 229, 255);
        case SyntaxType::Number:   return Color(245, 198, 134, 255);
        case SyntaxType::Operator: return Color(245, 198, 134, 255);
        case SyntaxType::Tag:      return Color(114, 193, 247, 255);
        case SyntaxType::Regexp:   return Color(109, 220, 126, 255);
        case SyntaxType::Special:  return Color(245, 198, 134, 255);
        default:                   return Color(229, 229, 229, 255);
    }
}

SyntaxType SyntaxHighlighter::syntaxTypeFromCapture(const std::string& captureName) {
    static const std::unordered_map<std::string, SyntaxType> mapping = {
        {"keyword", SyntaxType::Keyword},
        {"string", SyntaxType::String},
        {"comment", SyntaxType::Comment},
        {"function", SyntaxType::Function},
        {"type", SyntaxType::Type},
        {"variable", SyntaxType::Variable},
        {"number", SyntaxType::Number},
        {"operator", SyntaxType::Operator},
        {"tag", SyntaxType::Tag},
        {"regexp", SyntaxType::Regexp},
        {"special", SyntaxType::Special},
    };
    
    auto it = mapping.find(captureName);
    if (it != mapping.end()) {
        return it->second;
    }
    return SyntaxType::Unknown;
}

}  // namespace jules::highlighting
