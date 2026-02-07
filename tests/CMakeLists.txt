# Google Test integration
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.zip
)

# Prevent GTest from being installed (we only need it for testing, not distribution)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(INSTALL_GMOCK OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(googletest)

# Note: example_test.cpp and smoke_test.cpp were removed as they only tested
# trivial assertions. All meaningful tests are below.

# API Client test executable
add_executable(api_client_test api_client_test.cpp)
target_link_libraries(api_client_test PRIVATE
    gtest
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Network
    Qt6::Sql
    Qt6::Test
)
target_include_directories(api_client_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register API client test with CTest
add_test(NAME api_client COMMAND api_client_test)

# Session Repository test executable
add_executable(session_repository_test session_repository_test.cpp)
target_link_libraries(session_repository_test PRIVATE
    gtest
    jules_data
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
    jules_ui
    jules_data
    jules_api
    jules_data
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
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Test
)
target_include_directories(settings_manager_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register Settings Manager test with CTest
add_test(NAME settings_manager COMMAND settings_manager_test)

# HotkeyEdit widget test executable
# Note: Uses custom main() instead of gtest_main to control QApplication lifetime
# (fixes segfault in teardown on Fedora containers)
add_executable(hotkey_edit_test hotkey_edit_test.cpp)
target_link_libraries(hotkey_edit_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(hotkey_edit_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

# Register HotkeyEdit test with CTest
add_test(NAME hotkey_edit COMMAND hotkey_edit_test)

# Network Monitor test executable
# Uses custom main() for QApplication lifetime control
add_executable(network_monitor_test network_monitor_test.cpp)
target_link_libraries(network_monitor_test PRIVATE
    gtest
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Sql
    Qt6::Test
)
target_include_directories(network_monitor_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME network_monitor COMMAND network_monitor_test)

# Offline Sync Manager test executable
# Uses custom main() with in-memory SQLite database
add_executable(offline_sync_test offline_sync_test.cpp)
target_link_libraries(offline_sync_test PRIVATE
    gtest
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Network
    Qt6::Test
)
target_include_directories(offline_sync_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME offline_sync COMMAND offline_sync_test)

# Shared Syntax Cache test executable
# Uses gtest_main (no Qt app needed for pure C++ cache)
add_executable(shared_syntax_cache_test shared_syntax_cache_test.cpp)
target_link_libraries(shared_syntax_cache_test PRIVATE
    gtest
    gtest_main
    jules_rendering
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Sql
    Qt6::OpenGL
    Qt6::OpenGLWidgets
)
target_include_directories(shared_syntax_cache_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME shared_syntax_cache COMMAND shared_syntax_cache_test)

# Diff Precomputation Service test executable
add_executable(diff_precomputation_test diff_precomputation_test.cpp)
target_link_libraries(diff_precomputation_test PRIVATE
    gtest
    jules_rendering
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Network
    Qt6::Sql
    Qt6::OpenGL
    Qt6::OpenGLWidgets
    Qt6::Test
)
target_include_directories(diff_precomputation_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME diff_precomputation COMMAND diff_precomputation_test)

# Feedback Dialog test executable
add_executable(feedback_dialog_test feedback_dialog_test.cpp)
target_link_libraries(feedback_dialog_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(feedback_dialog_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME feedback_dialog COMMAND feedback_dialog_test)

# Diffs Database test executable
add_executable(diffs_database_test diffs_database_test.cpp)
target_link_libraries(diffs_database_test PRIVATE
    gtest
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Network
    Qt6::Test
)
target_include_directories(diffs_database_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME diffs_database COMMAND diffs_database_test)

# Filename Autocomplete Manager test executable
add_executable(filename_autocomplete_test filename_autocomplete_test.cpp)
target_link_libraries(filename_autocomplete_test PRIVATE
    gtest
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Network
    Qt6::Test
)
target_include_directories(filename_autocomplete_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME filename_autocomplete COMMAND filename_autocomplete_test)

# Flash Message Widget test executable
add_executable(flash_message_test flash_message_test.cpp)
target_link_libraries(flash_message_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(flash_message_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME flash_message COMMAND flash_message_test)

# Merge Conflict Dialog test executable
add_executable(merge_conflict_dialog_test merge_conflict_dialog_test.cpp)
target_link_libraries(merge_conflict_dialog_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(merge_conflict_dialog_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME merge_conflict_dialog COMMAND merge_conflict_dialog_test)

# Notification Manager test executable
add_executable(notification_manager_test notification_manager_test.cpp)
target_link_libraries(notification_manager_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::DBus
    Qt6::Test
)
target_include_directories(notification_manager_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME notification_manager COMMAND notification_manager_test)

# Update Checker test executable
add_executable(update_checker_test update_checker_test.cpp)
target_link_libraries(update_checker_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Test
)
target_include_directories(update_checker_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME update_checker COMMAND update_checker_test)

# Settings Dialog test executable
add_executable(settings_dialog_test settings_dialog_test.cpp)
target_link_libraries(settings_dialog_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(settings_dialog_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME settings_dialog COMMAND settings_dialog_test)

# Tray Popup Widget test executable
add_executable(tray_popup_widget_test tray_popup_widget_test.cpp)
target_link_libraries(tray_popup_widget_test PRIVATE
    gtest
    jules_ui
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Test
)
target_include_directories(tray_popup_widget_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME tray_popup_widget COMMAND tray_popup_widget_test)

# Diff Panel Widget test executable
add_executable(diff_panel_widget_test diff_panel_widget_test.cpp)
target_link_libraries(diff_panel_widget_test PRIVATE
    gtest
    jules_ui
    jules_rendering
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::OpenGL
    Qt6::OpenGLWidgets
    Qt6::Test
)
target_include_directories(diff_panel_widget_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME diff_panel_widget COMMAND diff_panel_widget_test)

# Database Migration test executable
add_executable(database_migration_test database_migration_test.cpp)
target_link_libraries(database_migration_test PRIVATE
    gtest
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Test
)
target_include_directories(database_migration_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME database_migration COMMAND database_migration_test)

# Markdown Rendering test executable
add_executable(markdown_rendering_test markdown_rendering_test.cpp)
target_link_libraries(markdown_rendering_test PRIVATE
    gtest
    jules_ui
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Test
)
target_include_directories(markdown_rendering_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME markdown_rendering COMMAND markdown_rendering_test)

# Session Detail Widget test executable
add_executable(session_detail_widget_test session_detail_widget_test.cpp)
target_link_libraries(session_detail_widget_test PRIVATE
    gtest
    jules_ui
    jules_data
    jules_api
    jules_data
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Sql
    Qt6::Test
)
target_include_directories(session_detail_widget_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME session_detail_widget COMMAND session_detail_widget_test)

# Command Palette test executable
add_executable(command_palette_test command_palette_test.cpp)
target_link_libraries(command_palette_test PRIVATE
    gtest
    jules_ui
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Test
)
target_include_directories(command_palette_test PRIVATE ${CMAKE_SOURCE_DIR}/include)

add_test(NAME command_palette COMMAND command_palette_test)
