cmake_minimum_required(VERSION 3.24)
project(Jules LANGUAGES CXX)

# Set C++ standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Qt 6 configuration
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 COMPONENTS Core Gui Widgets Network Sql OpenGL Test REQUIRED)

# Enable testing
enable_testing()

# Add main application executable
add_executable(jules-linux
    src/main.cpp
    resources/resources.qrc
)

# Link Qt modules to the application
target_link_libraries(jules-linux PRIVATE
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
