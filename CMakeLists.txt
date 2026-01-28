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

# Add main application executable
add_executable(jules-linux
    src/main.cpp
    resources/resources.qrc
)

# Link Qt modules to the application
target_link_libraries(jules-linux PRIVATE
    jules_api
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
