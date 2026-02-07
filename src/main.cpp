#include <QApplication>
#include <QGuiApplication>
#include <QStyleFactory>
#include "app/app_controller.h"

int main(int argc, char *argv[])
{
    QGuiApplication::setDesktopFileName("jules-linux");
    QApplication::setStyle("Fusion");
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinux");
    QCoreApplication::setApplicationName("Jules");

    jules::AppController controller;
    controller.initialize();

    int result = app.exec();

    controller.shutdown();
    return result;
}
