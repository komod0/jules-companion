cmake_minimum_required(VERSION 3.24)
project(Jules LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

include(FetchContent)

FetchContent_Declare(
    tree-sitter
    GIT_REPOSITORY https://github.com/tree-sitter/tree-sitter.git
    GIT_TAG        master
)
FetchContent_MakeAvailable(tree-sitter)

add_library(tree-sitter-lib STATIC
    ${tree-sitter_SOURCE_DIR}/lib/src/lib.c
)
target_include_directories(tree-sitter-lib PUBLIC
    ${tree-sitter_SOURCE_DIR}/lib/include
    ${tree-sitter_SOURCE_DIR}/lib/src
)

# Qt 6 configuration
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 COMPONENTS Core Gui Widgets Network Sql OpenGL Test REQUIRED)

# Enable testing
enable_testing()

# Jules API Library
add_library(jules_api STATIC
    src/api/jules_api_client.cpp
    include/api/jules_api_client.h
)

target_include_directories(jules_api PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(jules_api PUBLIC
    Qt6::Core
    Qt6::Network
)

# Jules Data Library
add_library(jules_data STATIC
    src/data/database.cpp
    src/data/session_repository.cpp
    include/data/database.h
    include/data/session_repository.h
)

target_include_directories(jules_data PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(jules_data PUBLIC
    jules_api
    Qt6::Core
    Qt6::Sql
)

add_library(jules_highlighting STATIC
    src/highlighting/syntax_highlighter.cpp
    include/highlighting/syntax_highlighter.h
)

target_include_directories(jules_highlighting PUBLIC 
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${tree-sitter_SOURCE_DIR}/lib/include
)
target_link_libraries(jules_highlighting PUBLIC
    tree-sitter-lib
    ${CMAKE_DL_LIBS}
)

set(GRAMMARS_DIR ${CMAKE_SOURCE_DIR}/grammars)

add_custom_target(download_grammars
    COMMAND ${CMAKE_COMMAND} -E make_directory ${GRAMMARS_DIR}
    COMMENT "Creating grammars directory"
)

add_dependencies(jules_highlighting download_grammars)

add_library(jules_ui STATIC
    src/ui/main_window.cpp
    include/ui/main_window.h
)

target_include_directories(jules_ui PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(jules_ui PUBLIC
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
)

add_executable(jules-linux
    src/main.cpp
    resources/resources.qrc
)

target_link_libraries(jules-linux PRIVATE
    jules_api
    jules_data
    jules_highlighting
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Sql
    Qt6::OpenGL
)

# Add include directory
target_include_directories(jules-linux PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)

# Add tests subdirectory
add_subdirectory(tests)
