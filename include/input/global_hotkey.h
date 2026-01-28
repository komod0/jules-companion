#pragma once

#include <QObject>
#include <QKeySequence>
#include <QPointer>
#include <QString>
#include <memory>

class QMainWindow;

namespace jules {

enum class DisplayServer {
    Unknown,
    X11,
    Wayland
};

enum class HotkeyBackend {
    Unavailable,
    X11,
    Portal
};

enum class ConflictStatus {
    NoConflict,
    AlreadyGrabbed,
    SystemReserved,
    Unknown
};

struct HotkeyBinding {
    Qt::Key key = Qt::Key_J;
    Qt::KeyboardModifiers modifiers = Qt::ControlModifier | Qt::AltModifier;
    
    QKeySequence toKeySequence() const;
    QString toDisplayString() const;
    
    bool operator==(const HotkeyBinding& other) const;
    bool operator!=(const HotkeyBinding& other) const;
};

struct HotkeyConflictResult {
    ConflictStatus status = ConflictStatus::Unknown;
    QString description;
};

class GlobalHotkeyBackend;

class GlobalHotkeyManager : public QObject {
    Q_OBJECT

public:
    explicit GlobalHotkeyManager(QObject* parent = nullptr);
    ~GlobalHotkeyManager() override;

    static DisplayServer detectDisplayServer();

    bool isAvailable() const;
    bool isRegistered() const;
    HotkeyBackend currentBackend() const;

    HotkeyBinding toggleWindowBinding() const;
    bool setToggleWindowBinding(const HotkeyBinding& binding);

    bool registerHotkeys();
    void unregisterHotkeys();

    HotkeyConflictResult checkConflict(const HotkeyBinding& binding) const;
    QString lastError() const;

    QMainWindow* targetWindow() const;
    void setTargetWindow(QMainWindow* window);

    void saveSettings();
    void loadSettings();
    void resetToDefaults();

    void simulateHotkeyActivated();

signals:
    void toggleWindowActivated();
    void bindingChanged(const HotkeyBinding& binding);
    void registrationFailed(const QString& error);
    void registrationPending();

private slots:
    void onTargetWindowDestroyed();
    void onBackendActivated();

private:
    void createBackend();
    void toggleTargetWindow();
    bool validateBinding(const HotkeyBinding& binding) const;

    std::unique_ptr<GlobalHotkeyBackend> m_backend;
    HotkeyBinding m_toggleBinding;
    QPointer<QMainWindow> m_targetWindow;
    QString m_lastError;
    bool m_registered = false;
};

class GlobalHotkeyBackend : public QObject {
    Q_OBJECT

public:
    explicit GlobalHotkeyBackend(QObject* parent = nullptr) : QObject(parent) {}
    virtual ~GlobalHotkeyBackend() = default;

    virtual bool registerHotkey(const HotkeyBinding& binding) = 0;
    virtual void unregisterHotkey() = 0;
    virtual bool isRegistered() const = 0;
    virtual HotkeyConflictResult checkConflict(const HotkeyBinding& binding) const = 0;
    virtual QString lastError() const = 0;

signals:
    void activated();
    void registrationFailed(const QString& error);
    void registrationPending();
};

class X11HotkeyBackend : public GlobalHotkeyBackend {
    Q_OBJECT

public:
    explicit X11HotkeyBackend(QObject* parent = nullptr);
    ~X11HotkeyBackend() override;

    bool registerHotkey(const HotkeyBinding& binding) override;
    void unregisterHotkey() override;
    bool isRegistered() const override;
    HotkeyConflictResult checkConflict(const HotkeyBinding& binding) const override;
    QString lastError() const override;

protected:
    bool nativeEventFilter(const QByteArray& eventType, void* message, qintptr* result);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

class PortalHotkeyBackend : public GlobalHotkeyBackend {
    Q_OBJECT

public:
    explicit PortalHotkeyBackend(QObject* parent = nullptr);
    ~PortalHotkeyBackend() override;

    bool registerHotkey(const HotkeyBinding& binding) override;
    void unregisterHotkey() override;
    bool isRegistered() const override;
    HotkeyConflictResult checkConflict(const HotkeyBinding& binding) const override;
    QString lastError() const override;

private slots:
    void onShortcutsRegistered();
    void onShortcutActivated(const QString& shortcutId);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}

Q_DECLARE_METATYPE(jules::HotkeyBinding)
Q_DECLARE_METATYPE(jules::DisplayServer)
Q_DECLARE_METATYPE(jules::HotkeyBackend)
Q_DECLARE_METATYPE(jules::ConflictStatus)
