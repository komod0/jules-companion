#include <gtest/gtest.h>
#include <QApplication>
#include <QMainWindow>

// Smoke test: Verify QApplication initializes without crash
TEST(SmokeTest, QApplicationInitializes) {
    // This test verifies that the Qt application can be created and initialized
    // without crashing. It's a basic sanity check for the Qt environment setup.
    int argc = 0;
    char *argv[] = {};
    
    QApplication app(argc, argv);
    
    // If we reach here, QApplication initialized successfully
    EXPECT_TRUE(true);
}

// Smoke test: Verify QMainWindow can be created
TEST(SmokeTest, QMainWindowCreates) {
    // This test verifies that a QMainWindow can be instantiated,
    // which is the base for the Jules application UI.
    int argc = 0;
    char *argv[] = {};
    
    QApplication app(argc, argv);
    QMainWindow window;
    
    // If we reach here, QMainWindow created successfully
    EXPECT_TRUE(true);
}
