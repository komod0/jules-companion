#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GRAMMARS_DIR="$PROJECT_ROOT/grammars"
BUILD_DIR="$PROJECT_ROOT/build/grammars_build"

mkdir -p "$GRAMMARS_DIR"
mkdir -p "$BUILD_DIR"

declare -A GRAMMAR_REPOS=(
    ["python"]="https://github.com/tree-sitter/tree-sitter-python"
    ["javascript"]="https://github.com/tree-sitter/tree-sitter-javascript"
    ["typescript"]="https://github.com/tree-sitter/tree-sitter-typescript"
    ["rust"]="https://github.com/tree-sitter/tree-sitter-rust"
    ["go"]="https://github.com/tree-sitter/tree-sitter-go"
    ["java"]="https://github.com/tree-sitter/tree-sitter-java"
    ["c"]="https://github.com/tree-sitter/tree-sitter-c"
    ["cpp"]="https://github.com/tree-sitter/tree-sitter-cpp"
    ["ruby"]="https://github.com/tree-sitter/tree-sitter-ruby"
    ["php"]="https://github.com/tree-sitter/tree-sitter-php"
    ["swift"]="https://github.com/alex-pinkus/tree-sitter-swift"
    ["kotlin"]="https://github.com/fwcd/tree-sitter-kotlin"
    ["scala"]="https://github.com/tree-sitter/tree-sitter-scala"
    ["lua"]="https://github.com/tree-sitter-grammars/tree-sitter-lua"
    ["bash"]="https://github.com/tree-sitter/tree-sitter-bash"
    ["sql"]="https://github.com/DerekStride/tree-sitter-sql"
    ["html"]="https://github.com/tree-sitter/tree-sitter-html"
    ["css"]="https://github.com/tree-sitter/tree-sitter-css"
    ["json"]="https://github.com/tree-sitter/tree-sitter-json"
    ["yaml"]="https://github.com/tree-sitter-grammars/tree-sitter-yaml"
)

declare -A GRAMMAR_SUBDIRS=(
    ["typescript"]="typescript"
    ["php"]="php"
)

build_grammar() {
    local name=$1
    local repo=$2
    local subdir=${GRAMMAR_SUBDIRS[$name]:-""}
    local clone_dir="$BUILD_DIR/$name"
    local src_dir="$clone_dir"
    
    if [[ -n "$subdir" ]]; then
        src_dir="$clone_dir/$subdir"
    fi
    
    echo "Building grammar: $name"
    
    if [[ ! -d "$clone_dir" ]]; then
        echo "  Cloning $repo..."
        git clone --depth 1 "$repo" "$clone_dir" 2>/dev/null || {
            echo "  Failed to clone $name, skipping..."
            return 1
        }
    fi
    
    local src_file="$src_dir/src/parser.c"
    local scanner_c="$src_dir/src/scanner.c"
    local scanner_cc="$src_dir/src/scanner.cc"
    
    if [[ ! -f "$src_file" ]]; then
        echo "  No parser.c found for $name, skipping..."
        return 1
    fi
    
    local output="$GRAMMARS_DIR/libtree-sitter-$name.so"
    local compile_cmd="cc -shared -fPIC -O2"
    compile_cmd="$compile_cmd -I$src_dir/src"
    compile_cmd="$compile_cmd $src_file"
    
    if [[ -f "$scanner_c" ]]; then
        compile_cmd="$compile_cmd $scanner_c"
    fi
    
    if [[ -f "$scanner_cc" ]]; then
        compile_cmd="c++ -shared -fPIC -O2"
        compile_cmd="$compile_cmd -I$src_dir/src"
        compile_cmd="$compile_cmd $src_file"
        compile_cmd="$compile_cmd $scanner_cc"
    fi
    
    compile_cmd="$compile_cmd -o $output"
    
    echo "  Compiling..."
    eval $compile_cmd 2>/dev/null || {
        echo "  Compilation failed for $name"
        return 1
    }
    
    echo "  Built: $output"
    return 0
}

echo "Building tree-sitter grammars..."
echo "Output directory: $GRAMMARS_DIR"
echo ""

success_count=0
fail_count=0

for name in "${!GRAMMAR_REPOS[@]}"; do
    if build_grammar "$name" "${GRAMMAR_REPOS[$name]}"; then
        ((success_count++))
    else
        ((fail_count++))
    fi
done

echo ""
echo "Build complete: $success_count succeeded, $fail_count failed"
echo "Grammar libraries are in: $GRAMMARS_DIR"

ls -la "$GRAMMARS_DIR"/*.so 2>/dev/null || echo "No grammar files built"
