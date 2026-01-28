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
