#include <QApplication>
#include <QGuiApplication>

#include "ui/main_window.h"

int main(int argc, char *argv[])
{
    QGuiApplication::setDesktopFileName("jules-linux");
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinux");
    QCoreApplication::setApplicationName("Jules");

    jules::MainWindow window;
    window.restoreWindowState();
    window.show();

    int result = app.exec();
    
    window.saveWindowState();
    return result;
}
