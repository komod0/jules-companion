# Google Test integration
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.zip
)
FetchContent_MakeAvailable(googletest)

# Example test executable
add_executable(example_test example_test.cpp)
target_link_libraries(example_test PRIVATE gtest gtest_main Qt6::Core)

# Register test with CTest
add_test(NAME ExampleTest COMMAND example_test)

# Smoke test executable
add_executable(smoke_test smoke_test.cpp)
target_link_libraries(smoke_test PRIVATE gtest gtest_main Qt6::Core Qt6::Gui Qt6::Widgets)

# Register smoke test with CTest
add_test(NAME smoke COMMAND smoke_test)

# API Client test executable
add_executable(api_client_test api_client_test.cpp)
target_link_libraries(api_client_test PRIVATE 
    gtest 
    jules_api
    Qt6::Core 
    Qt6::Network
    Qt6::Test
)
target_include_directories(api_client_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register API client test with CTest
add_test(NAME api_client COMMAND api_client_test)

# Session Repository test executable
add_executable(session_repository_test session_repository_test.cpp)
target_link_libraries(session_repository_test PRIVATE 
    gtest 
    jules_api
    jules_data
    Qt6::Core 
    Qt6::Sql
    Qt6::Test
)
target_include_directories(session_repository_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register Session Repository test with CTest
add_test(NAME session_repository COMMAND session_repository_test)

add_executable(syntax_highlighter_test syntax_highlighter_test.cpp)
target_link_libraries(syntax_highlighter_test PRIVATE 
    gtest 
    gtest_main
    jules_highlighting
)
target_include_directories(syntax_highlighter_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME syntax_highlighter COMMAND syntax_highlighter_test)

set_tests_properties(syntax_highlighter PROPERTIES
    ENVIRONMENT "TREE_SITTER_GRAMMAR_PATH=${CMAKE_SOURCE_DIR}/grammars"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_executable(main_window_test main_window_test.cpp)
target_link_libraries(main_window_test PRIVATE 
    gtest 
    jules_ui
    Qt6::Core 
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(main_window_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME main_window COMMAND main_window_test)

# Font Atlas test executable
add_executable(font_atlas_test font_atlas_test.cpp)
target_link_libraries(font_atlas_test PRIVATE 
    gtest 
    jules_rendering
    Qt6::Core 
    Qt6::Gui
    Qt6::OpenGL
    Qt6::OpenGLWidgets
)
target_include_directories(font_atlas_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME font_atlas COMMAND font_atlas_test)

add_executable(session_manager_test session_manager_test.cpp)
target_link_libraries(session_manager_test PRIVATE 
    gtest 
    jules_api
    jules_data
    jules_ui
    Qt6::Core 
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Test
)
target_include_directories(session_manager_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME session_manager COMMAND session_manager_test)

add_executable(system_tray_test system_tray_test.cpp)
target_link_libraries(system_tray_test PRIVATE 
    gtest 
    jules_ui
    Qt6::Core 
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(system_tray_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME system_tray COMMAND system_tray_test)

add_executable(global_hotkeys_test global_hotkeys_test.cpp)
target_link_libraries(global_hotkeys_test PRIVATE 
    gtest 
    jules_input
    Qt6::Core 
    Qt6::Gui
    Qt6::Widgets
    Qt6::DBus
    Qt6::Test
)
target_include_directories(global_hotkeys_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME global_hotkeys COMMAND global_hotkeys_test)

# Diff Renderer test executable
add_executable(diff_renderer_test diff_renderer_test.cpp)
target_link_libraries(diff_renderer_test PRIVATE 
    gtest 
    gtest_main
    jules_rendering
    jules_highlighting
    Qt6::Core 
    Qt6::Gui
    Qt6::OpenGL
    Qt6::OpenGLWidgets
)
target_include_directories(diff_renderer_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME diff_renderer COMMAND diff_renderer_test)

set_tests_properties(diff_renderer PROPERTIES
    ENVIRONMENT "TREE_SITTER_GRAMMAR_PATH=${CMAKE_SOURCE_DIR}/grammars"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_executable(boids_test boids_test.cpp)
target_link_libraries(boids_test PRIVATE 
    gtest 
    jules_rendering
    Qt6::Core 
    Qt6::Gui
    Qt6::OpenGL
    Qt6::OpenGLWidgets
)
target_include_directories(boids_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME boids COMMAND boids_test)

set_tests_properties(boids PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_executable(wave_widget_test wave_widget_test.cpp)
target_link_libraries(wave_widget_test PRIVATE 
    gtest 
    jules_rendering
    Qt6::Core 
    Qt6::Gui
    Qt6::OpenGL
    Qt6::OpenGLWidgets
)
target_include_directories(wave_widget_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME wave_widget COMMAND wave_widget_test)

set_tests_properties(wave_widget PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

# Settings Manager test executable
add_executable(settings_manager_test settings_manager_test.cpp)
target_link_libraries(settings_manager_test PRIVATE
    gtest
    gtest_main
    jules_data
    Qt6::Core
    Qt6::Test
)
target_include_directories(settings_manager_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register Settings Manager test with CTest
add_test(NAME settings_manager COMMAND settings_manager_test)

# HotkeyEdit widget test executable
add_executable(hotkey_edit_test hotkey_edit_test.cpp)
target_link_libraries(hotkey_edit_test PRIVATE
    gtest
    gtest_main
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(hotkey_edit_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register HotkeyEdit test with CTest
add_test(NAME hotkey_edit COMMAND hotkey_edit_test)
