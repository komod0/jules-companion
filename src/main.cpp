#include <QApplication>
#include <QGuiApplication>
#include <QStyleHints>

#include "ui/main_window.h"
#include "data/settings_manager.h"

int main(int argc, char *argv[])
{
    QGuiApplication::setDesktopFileName("jules-linux");
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinux");
    QCoreApplication::setApplicationName("Jules");

    // Initialize settings manager and apply saved theme
    auto& settings = SettingsManager::instance();
    
    jules::MainWindow window;
    
    // Apply saved theme on startup
    window.setTheme(settings.theme());
    
    // Connect theme changes to MainWindow
    QObject::connect(&settings, &SettingsManager::themeChanged,
                     &window, &jules::MainWindow::setTheme);
    
    window.restoreWindowState();
    window.show();

    int result = app.exec();
    
    window.saveWindowState();
    return result;
}
