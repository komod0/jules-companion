#include <QApplication>
#include <QMainWindow>

int main(int argc, char *argv[])
{
    // Create the Qt application
    QApplication app(argc, argv);

    // Create a minimal main window
    QMainWindow window;
    window.setWindowTitle("Jules - Linux Port");
    window.resize(800, 600);

    // Show the window
    window.show();

    // Run the application event loop
    return app.exec();
}
