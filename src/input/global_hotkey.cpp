#include "input/global_hotkey.h"

#include <QApplication>
#include <QAbstractNativeEventFilter>
#include <QMainWindow>
#include <QSettings>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QUuid>
#include <QTimer>

#ifdef JULES_HAS_XCB
#include <xcb/xcb.h>
#include <xcb/xcb_keysyms.h>
#include <X11/X.h>
#include <X11/keysym.h>
#endif

namespace jules {

namespace {
    const QString SETTINGS_KEY_TOGGLE = QStringLiteral("hotkeys/toggleWindow");
    const QString SETTINGS_KEY_MODIFIER = QStringLiteral("hotkeys/toggleModifiers");
}

QKeySequence HotkeyBinding::toKeySequence() const {
    int keyWithModifiers = static_cast<int>(key) | static_cast<int>(modifiers);
    return QKeySequence(keyWithModifiers);
}

QString HotkeyBinding::toDisplayString() const {
    return toKeySequence().toString(QKeySequence::NativeText);
}

bool HotkeyBinding::operator==(const HotkeyBinding& other) const {
    return key == other.key && modifiers == other.modifiers;
}

bool HotkeyBinding::operator!=(const HotkeyBinding& other) const {
    return !(*this == other);
}

DisplayServer GlobalHotkeyManager::detectDisplayServer() {
    QString sessionType = qEnvironmentVariable("XDG_SESSION_TYPE");
    QString waylandDisplay = qEnvironmentVariable("WAYLAND_DISPLAY");
    QString x11Display = qEnvironmentVariable("DISPLAY");
    
    if (sessionType == QLatin1String("wayland") || !waylandDisplay.isEmpty()) {
        return DisplayServer::Wayland;
    }
    
    if (!x11Display.isEmpty()) {
        return DisplayServer::X11;
    }
    
    return DisplayServer::Unknown;
}

GlobalHotkeyManager::GlobalHotkeyManager(QObject* parent)
    : QObject(parent)
{
    loadSettings();
    createBackend();
}

GlobalHotkeyManager::~GlobalHotkeyManager() {
    unregisterHotkeys();
}

void GlobalHotkeyManager::createBackend() {
    DisplayServer server = detectDisplayServer();
    
    switch (server) {
        case DisplayServer::X11:
#ifdef JULES_HAS_XCB
            m_backend = std::make_unique<X11HotkeyBackend>(this);
            connect(m_backend.get(), &GlobalHotkeyBackend::activated,
                    this, &GlobalHotkeyManager::onBackendActivated);
            connect(m_backend.get(), &GlobalHotkeyBackend::registrationFailed,
                    this, &GlobalHotkeyManager::registrationFailed);
#endif
            break;
            
        case DisplayServer::Wayland:
            m_backend = std::make_unique<PortalHotkeyBackend>(this);
            connect(m_backend.get(), &GlobalHotkeyBackend::activated,
                    this, &GlobalHotkeyManager::onBackendActivated);
            connect(m_backend.get(), &GlobalHotkeyBackend::registrationFailed,
                    this, &GlobalHotkeyManager::registrationFailed);
            connect(m_backend.get(), &GlobalHotkeyBackend::registrationPending,
                    this, &GlobalHotkeyManager::registrationPending);
            break;
            
        case DisplayServer::Unknown:
            break;
    }
}

bool GlobalHotkeyManager::isAvailable() const {
    return m_backend != nullptr;
}

bool GlobalHotkeyManager::isRegistered() const {
    return m_registered && m_backend && m_backend->isRegistered();
}

HotkeyBackend GlobalHotkeyManager::currentBackend() const {
    if (!m_backend) {
        return HotkeyBackend::Unavailable;
    }
    
    if (dynamic_cast<X11HotkeyBackend*>(m_backend.get())) {
        return HotkeyBackend::X11;
    }
    
    if (dynamic_cast<PortalHotkeyBackend*>(m_backend.get())) {
        return HotkeyBackend::Portal;
    }
    
    return HotkeyBackend::Unavailable;
}

HotkeyBinding GlobalHotkeyManager::toggleWindowBinding() const {
    return m_toggleBinding;
}

bool GlobalHotkeyManager::setToggleWindowBinding(const HotkeyBinding& binding) {
    if (!validateBinding(binding)) {
        return false;
    }
    
    if (binding == m_toggleBinding) {
        return true;
    }
    
    bool wasRegistered = isRegistered();
    if (wasRegistered) {
        unregisterHotkeys();
    }
    
    m_toggleBinding = binding;
    emit bindingChanged(binding);
    
    if (wasRegistered) {
        registerHotkeys();
    }
    
    return true;
}

bool GlobalHotkeyManager::validateBinding(const HotkeyBinding& binding) const {
    if (binding.key == Qt::Key_unknown) {
        return false;
    }
    
    if (binding.modifiers == Qt::NoModifier) {
        return false;
    }
    
    return true;
}

bool GlobalHotkeyManager::registerHotkeys() {
    if (!m_backend) {
        m_lastError = tr("No hotkey backend available");
        emit registrationFailed(m_lastError);
        return false;
    }
    
    m_registered = m_backend->registerHotkey(m_toggleBinding);
    
    if (!m_registered) {
        m_lastError = m_backend->lastError();
    }
    
    return m_registered;
}

void GlobalHotkeyManager::unregisterHotkeys() {
    if (m_backend) {
        m_backend->unregisterHotkey();
    }
    m_registered = false;
}

HotkeyConflictResult GlobalHotkeyManager::checkConflict(const HotkeyBinding& binding) const {
    if (!m_backend) {
        return {ConflictStatus::Unknown, tr("No backend available")};
    }
    
    return m_backend->checkConflict(binding);
}

QString GlobalHotkeyManager::lastError() const {
    return m_lastError;
}

QMainWindow* GlobalHotkeyManager::targetWindow() const {
    return m_targetWindow;
}

void GlobalHotkeyManager::setTargetWindow(QMainWindow* window) {
    if (m_targetWindow) {
        disconnect(m_targetWindow, &QObject::destroyed,
                   this, &GlobalHotkeyManager::onTargetWindowDestroyed);
    }
    
    m_targetWindow = window;
    
    if (m_targetWindow) {
        connect(m_targetWindow, &QObject::destroyed,
                this, &GlobalHotkeyManager::onTargetWindowDestroyed);
    }
}

void GlobalHotkeyManager::onTargetWindowDestroyed() {
    m_targetWindow = nullptr;
}

void GlobalHotkeyManager::onBackendActivated() {
    toggleTargetWindow();
    emit toggleWindowActivated();
}

void GlobalHotkeyManager::toggleTargetWindow() {
    if (!m_targetWindow) {
        return;
    }
    
    if (m_targetWindow->isVisible()) {
        m_targetWindow->hide();
    } else {
        m_targetWindow->show();
        m_targetWindow->raise();
        m_targetWindow->activateWindow();
    }
}

void GlobalHotkeyManager::simulateHotkeyActivated() {
    onBackendActivated();
}

void GlobalHotkeyManager::saveSettings() {
    QSettings settings;
    settings.setValue(SETTINGS_KEY_TOGGLE, static_cast<int>(m_toggleBinding.key));
    settings.setValue(SETTINGS_KEY_MODIFIER, static_cast<int>(m_toggleBinding.modifiers));
}

void GlobalHotkeyManager::loadSettings() {
    QSettings settings;
    
    int key = settings.value(SETTINGS_KEY_TOGGLE, static_cast<int>(Qt::Key_J)).toInt();
    int mods = settings.value(SETTINGS_KEY_MODIFIER, 
                              static_cast<int>(Qt::ControlModifier | Qt::AltModifier)).toInt();
    
    m_toggleBinding.key = static_cast<Qt::Key>(key);
    m_toggleBinding.modifiers = static_cast<Qt::KeyboardModifiers>(mods);
    
    if (!validateBinding(m_toggleBinding)) {
        resetToDefaults();
    }
}

void GlobalHotkeyManager::resetToDefaults() {
    m_toggleBinding.key = Qt::Key_J;
    m_toggleBinding.modifiers = Qt::ControlModifier | Qt::AltModifier;
}

#ifdef JULES_HAS_XCB

struct X11HotkeyBackend::Impl : public QAbstractNativeEventFilter {
    xcb_connection_t* connection = nullptr;
    xcb_window_t rootWindow = 0;
    xcb_key_symbols_t* keySymbols = nullptr;
    xcb_keycode_t keycode = 0;
    uint16_t modifiers = 0;
    bool registered = false;
    QString lastError;
    HotkeyBinding currentBinding;
    X11HotkeyBackend* backend = nullptr;
    
    bool nativeEventFilter(const QByteArray& eventType, void* message, qintptr* result) override {
        Q_UNUSED(result)
        
        if (eventType != "xcb_generic_event_t" || !registered) {
            return false;
        }
        
        auto* event = static_cast<xcb_generic_event_t*>(message);
        uint8_t responseType = event->response_type & ~0x80;
        
        if (responseType == XCB_KEY_PRESS) {
            auto* keyEvent = reinterpret_cast<xcb_key_press_event_t*>(event);
            
            uint16_t maskedState = keyEvent->state & ~(XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2);
            
            if (keyEvent->detail == keycode && maskedState == modifiers) {
                if (backend) {
                    emit backend->activated();
                }
                return true;
            }
        }
        
        return false;
    }
};

namespace {
    
uint16_t qtModifiersToX11(Qt::KeyboardModifiers mods) {
    uint16_t x11Mods = 0;
    
    if (mods & Qt::ShiftModifier) x11Mods |= XCB_MOD_MASK_SHIFT;
    if (mods & Qt::ControlModifier) x11Mods |= XCB_MOD_MASK_CONTROL;
    if (mods & Qt::AltModifier) x11Mods |= XCB_MOD_MASK_1;
    if (mods & Qt::MetaModifier) x11Mods |= XCB_MOD_MASK_4;
    
    return x11Mods;
}

xcb_keycode_t qtKeyToX11Keycode(xcb_key_symbols_t* symbols, Qt::Key key) {
    KeySym keysym = 0;
    
    if (key >= Qt::Key_A && key <= Qt::Key_Z) {
        keysym = XK_a + (key - Qt::Key_A);
    } else if (key >= Qt::Key_0 && key <= Qt::Key_9) {
        keysym = XK_0 + (key - Qt::Key_0);
    } else {
        switch (key) {
            case Qt::Key_Space: keysym = XK_space; break;
            case Qt::Key_Escape: keysym = XK_Escape; break;
            case Qt::Key_Return: keysym = XK_Return; break;
            case Qt::Key_Tab: keysym = XK_Tab; break;
            case Qt::Key_Delete: keysym = XK_Delete; break;
            default: return 0;
        }
    }
    
    xcb_keycode_t* keycodes = xcb_key_symbols_get_keycode(symbols, keysym);
    if (!keycodes) return 0;
    
    xcb_keycode_t result = keycodes[0];
    free(keycodes);
    return result;
}

}

X11HotkeyBackend::X11HotkeyBackend(QObject* parent)
    : GlobalHotkeyBackend(parent)
    , m_impl(std::make_unique<Impl>())
{
    m_impl->backend = this;
    
    QString display = qEnvironmentVariable("DISPLAY");
    if (!display.isEmpty()) {
        int screen = 0;
        m_impl->connection = xcb_connect(nullptr, &screen);
        
        if (m_impl->connection && !xcb_connection_has_error(m_impl->connection)) {
            xcb_screen_iterator_t iter = xcb_setup_roots_iterator(xcb_get_setup(m_impl->connection));
            for (int i = 0; i < screen && iter.rem; i++) {
                xcb_screen_next(&iter);
            }
            if (iter.data) {
                m_impl->rootWindow = iter.data->root;
            }
            
            m_impl->keySymbols = xcb_key_symbols_alloc(m_impl->connection);
        }
    }
}

X11HotkeyBackend::~X11HotkeyBackend() {
    unregisterHotkey();
    
    if (m_impl->keySymbols) {
        xcb_key_symbols_free(m_impl->keySymbols);
    }
    
    if (m_impl->connection) {
        xcb_disconnect(m_impl->connection);
    }
}

bool X11HotkeyBackend::registerHotkey(const HotkeyBinding& binding) {
    if (!m_impl->connection || !m_impl->keySymbols) {
        m_impl->lastError = tr("X11 connection not available");
        emit registrationFailed(m_impl->lastError);
        return false;
    }
    
    unregisterHotkey();
    
    m_impl->keycode = qtKeyToX11Keycode(m_impl->keySymbols, binding.key);
    if (m_impl->keycode == 0) {
        m_impl->lastError = tr("Could not convert key to X11 keycode");
        emit registrationFailed(m_impl->lastError);
        return false;
    }
    
    m_impl->modifiers = qtModifiersToX11(binding.modifiers);
    m_impl->currentBinding = binding;
    
    uint16_t modCombinations[] = {
        m_impl->modifiers,
        static_cast<uint16_t>(m_impl->modifiers | XCB_MOD_MASK_LOCK),
        static_cast<uint16_t>(m_impl->modifiers | XCB_MOD_MASK_2),
        static_cast<uint16_t>(m_impl->modifiers | XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2)
    };
    
    for (uint16_t mods : modCombinations) {
        xcb_void_cookie_t cookie = xcb_grab_key_checked(
            m_impl->connection,
            1,
            m_impl->rootWindow,
            mods,
            m_impl->keycode,
            XCB_GRAB_MODE_ASYNC,
            XCB_GRAB_MODE_ASYNC
        );
        
        xcb_generic_error_t* error = xcb_request_check(m_impl->connection, cookie);
        if (error) {
            m_impl->lastError = tr("Failed to grab key: X11 BadAccess (key already grabbed)");
            free(error);
            unregisterHotkey();
            emit registrationFailed(m_impl->lastError);
            return false;
        }
    }
    
    xcb_flush(m_impl->connection);
    m_impl->registered = true;
    
    qApp->installNativeEventFilter(m_impl.get());
    
    return true;
}

void X11HotkeyBackend::unregisterHotkey() {
    if (!m_impl->connection || !m_impl->registered) {
        return;
    }
    
    qApp->removeNativeEventFilter(m_impl.get());
    
    uint16_t modCombinations[] = {
        m_impl->modifiers,
        static_cast<uint16_t>(m_impl->modifiers | XCB_MOD_MASK_LOCK),
        static_cast<uint16_t>(m_impl->modifiers | XCB_MOD_MASK_2),
        static_cast<uint16_t>(m_impl->modifiers | XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2)
    };
    
    for (uint16_t mods : modCombinations) {
        xcb_ungrab_key(
            m_impl->connection,
            m_impl->keycode,
            m_impl->rootWindow,
            mods
        );
    }
    
    xcb_flush(m_impl->connection);
    m_impl->registered = false;
}

bool X11HotkeyBackend::isRegistered() const {
    return m_impl->registered;
}

HotkeyConflictResult X11HotkeyBackend::checkConflict(const HotkeyBinding& binding) const {
    HotkeyConflictResult result;
    
    if (binding.key == Qt::Key_Delete && 
        binding.modifiers == (Qt::ControlModifier | Qt::AltModifier)) {
        result.status = ConflictStatus::SystemReserved;
        result.description = tr("Ctrl+Alt+Delete is reserved by the system");
        return result;
    }
    
    result.status = ConflictStatus::NoConflict;
    return result;
}

QString X11HotkeyBackend::lastError() const {
    return m_impl->lastError;
}

bool X11HotkeyBackend::nativeEventFilter(const QByteArray&, void*, qintptr*) {
    return false;
}

#else

struct X11HotkeyBackend::Impl {};
X11HotkeyBackend::X11HotkeyBackend(QObject* parent) : GlobalHotkeyBackend(parent) {}
X11HotkeyBackend::~X11HotkeyBackend() = default;
bool X11HotkeyBackend::registerHotkey(const HotkeyBinding&) { return false; }
void X11HotkeyBackend::unregisterHotkey() {}
bool X11HotkeyBackend::isRegistered() const { return false; }
HotkeyConflictResult X11HotkeyBackend::checkConflict(const HotkeyBinding&) const { 
    return {ConflictStatus::Unknown, tr("X11 not available")}; 
}
QString X11HotkeyBackend::lastError() const { return tr("X11 not available"); }
bool X11HotkeyBackend::nativeEventFilter(const QByteArray&, void*, qintptr*) { return false; }

#endif

struct PortalHotkeyBackend::Impl {
    QDBusInterface* portalInterface = nullptr;
    QString sessionPath;
    QString requestToken;
    bool registered = false;
    bool pending = false;
    QString lastError;
    HotkeyBinding currentBinding;
};

PortalHotkeyBackend::PortalHotkeyBackend(QObject* parent)
    : GlobalHotkeyBackend(parent)
    , m_impl(std::make_unique<Impl>())
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    
    m_impl->portalInterface = new QDBusInterface(
        QStringLiteral("org.freedesktop.portal.Desktop"),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.portal.GlobalShortcuts"),
        bus,
        this
    );
    
    bus.connect(
        QStringLiteral("org.freedesktop.portal.Desktop"),
        QString(),
        QStringLiteral("org.freedesktop.portal.GlobalShortcuts"),
        QStringLiteral("Activated"),
        this,
        SLOT(onShortcutActivated(QString))
    );
}

PortalHotkeyBackend::~PortalHotkeyBackend() {
    unregisterHotkey();
}

bool PortalHotkeyBackend::registerHotkey(const HotkeyBinding& binding) {
    if (!m_impl->portalInterface || !m_impl->portalInterface->isValid()) {
        m_impl->lastError = tr("GlobalShortcuts portal not available");
        emit registrationFailed(m_impl->lastError);
        return false;
    }
    
    unregisterHotkey();
    m_impl->currentBinding = binding;
    
    m_impl->requestToken = QUuid::createUuid().toString(QUuid::WithoutBraces);
    
    QVariantMap options;
    options[QStringLiteral("handle_token")] = m_impl->requestToken;
    options[QStringLiteral("session_handle_token")] = QStringLiteral("jules_session");
    
    QDBusMessage createSession = m_impl->portalInterface->call(
        QStringLiteral("CreateSession"),
        options
    );
    
    if (createSession.type() == QDBusMessage::ErrorMessage) {
        m_impl->lastError = createSession.errorMessage();
        emit registrationFailed(m_impl->lastError);
        return false;
    }
    
    QDBusObjectPath sessionPath = createSession.arguments().at(0).value<QDBusObjectPath>();
    m_impl->sessionPath = sessionPath.path();
    
    QVariantMap shortcut;
    shortcut[QStringLiteral("description")] = tr("Toggle Jules window");
    shortcut[QStringLiteral("preferred_trigger")] = binding.toKeySequence().toString();
    
    QList<QVariant> shortcuts;
    QVariantMap shortcutEntry;
    shortcutEntry[QStringLiteral("jules-toggle")] = shortcut;
    shortcuts.append(QVariant::fromValue(shortcutEntry));
    
    QVariantMap bindOptions;
    bindOptions[QStringLiteral("handle_token")] = QUuid::createUuid().toString(QUuid::WithoutBraces);
    
    QDBusMessage bindMsg = m_impl->portalInterface->call(
        QStringLiteral("BindShortcuts"),
        QVariant::fromValue(sessionPath),
        QVariant::fromValue(shortcuts),
        QString(),
        bindOptions
    );
    
    if (bindMsg.type() == QDBusMessage::ErrorMessage) {
        m_impl->lastError = bindMsg.errorMessage();
        emit registrationFailed(m_impl->lastError);
        return false;
    }
    
    m_impl->pending = true;
    emit registrationPending();
    
    QTimer::singleShot(100, this, &PortalHotkeyBackend::onShortcutsRegistered);
    
    return true;
}

void PortalHotkeyBackend::unregisterHotkey() {
    if (!m_impl->sessionPath.isEmpty() && m_impl->portalInterface) {
        QDBusMessage closeMsg = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.portal.Desktop"),
            m_impl->sessionPath,
            QStringLiteral("org.freedesktop.portal.Session"),
            QStringLiteral("Close")
        );
        QDBusConnection::sessionBus().send(closeMsg);
    }
    
    m_impl->sessionPath.clear();
    m_impl->registered = false;
    m_impl->pending = false;
}

bool PortalHotkeyBackend::isRegistered() const {
    return m_impl->registered;
}

HotkeyConflictResult PortalHotkeyBackend::checkConflict(const HotkeyBinding& binding) const {
    Q_UNUSED(binding)
    
    HotkeyConflictResult result;
    result.status = ConflictStatus::NoConflict;
    return result;
}

QString PortalHotkeyBackend::lastError() const {
    return m_impl->lastError;
}

void PortalHotkeyBackend::onShortcutsRegistered() {
    m_impl->registered = true;
    m_impl->pending = false;
}

void PortalHotkeyBackend::onShortcutActivated(const QString& shortcutId) {
    if (shortcutId == QLatin1String("jules-toggle") || 
        shortcutId.contains(QLatin1String("jules"))) {
        emit activated();
    }
}

}
