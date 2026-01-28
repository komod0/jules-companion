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

find_package(Qt6 COMPONENTS Core Gui Widgets Network Sql OpenGL OpenGLWidgets DBus Test REQUIRED)

# Find FreeType for font rendering
find_package(Freetype REQUIRED)

# Find X11/XCB for global hotkeys (optional - only on X11 systems)
find_package(X11 QUIET)
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(XCB QUIET xcb xcb-keysyms)
endif()

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
    src/ui/session_list_widget.cpp
    src/ui/new_session_dialog.cpp
    src/ui/session_detail_widget.cpp
    src/ui/system_tray.cpp
    include/ui/main_window.h
    include/ui/session_list_widget.h
    include/ui/new_session_dialog.h
    include/ui/session_detail_widget.h
    include/ui/system_tray.h
)

target_include_directories(jules_ui PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(jules_ui PUBLIC
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
)

# Jules Input Library (Global Hotkeys - X11/Wayland)
add_library(jules_input STATIC
    src/input/global_hotkey.cpp
    include/input/global_hotkey.h
)

target_include_directories(jules_input PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(jules_input PUBLIC
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::DBus
)

if(XCB_FOUND)
    target_compile_definitions(jules_input PRIVATE JULES_HAS_XCB=1)
    target_include_directories(jules_input PRIVATE ${XCB_INCLUDE_DIRS})
    target_link_libraries(jules_input PRIVATE ${XCB_LIBRARIES})
endif()

# Jules Rendering Library (OpenGL + FreeType)
add_library(jules_rendering STATIC
    src/rendering/font_atlas.cpp
    src/rendering/opengl_widget.cpp
    src/rendering/diff_renderer.cpp
    src/rendering/boids_widget.cpp
    include/rendering/font_atlas.h
    include/rendering/opengl_widget.h
    include/rendering/diff_renderer.h
    include/rendering/boids_widget.h
)

target_include_directories(jules_rendering PUBLIC 
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${FREETYPE_INCLUDE_DIRS}
)
target_link_libraries(jules_rendering PUBLIC
    jules_highlighting
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::OpenGL
    Qt6::OpenGLWidgets
    ${FREETYPE_LIBRARIES}
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
    jules_input
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Sql
    Qt6::OpenGL
    Qt6::DBus
)

# Add include directory
target_include_directories(jules-linux PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)

# OpenGL Text Rendering Spike executable
add_executable(opengl_spike
    src/opengl_spike_main.cpp
    resources/shaders.qrc
)

target_include_directories(opengl_spike PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(opengl_spike PRIVATE
    jules_rendering
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::OpenGL
    Qt6::OpenGLWidgets
)

# Copy shaders to build directory for runtime loading
add_custom_command(TARGET opengl_spike POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${CMAKE_SOURCE_DIR}/shaders
    $<TARGET_FILE_DIR:opengl_spike>/shaders
)

# Add tests subdirectory
add_subdirectory(tests)
