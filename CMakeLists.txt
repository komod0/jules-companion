cmake_minimum_required(VERSION 3.24)
project(Jules LANGUAGES CXX)

# Set C++ standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Qt 6 configuration
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 COMPONENTS Core Test REQUIRED)

# Enable testing
enable_testing()

# Add tests subdirectory
add_subdirectory(tests)
