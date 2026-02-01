#include "ui/hotkey_edit.h"
#include <QKeyEvent>
#include <QFocusEvent>
#include <QStyle>

namespace jules {

HotkeyEdit::HotkeyEdit(QWidget* parent)
    : QLineEdit(parent)
{
    setReadOnly(true);
    setPlaceholderText(tr("Click to set shortcut..."));
    updateDisplay();
}

HotkeyBinding HotkeyEdit::binding() const {
    return m_binding;
}

void HotkeyEdit::setBinding(const HotkeyBinding& binding) {
    if (m_binding != binding) {
        m_binding = binding;
        updateDisplay();
        emit bindingChanged(m_binding);
    }
}

void HotkeyEdit::clear() {
    m_binding = HotkeyBinding{};
    updateDisplay();
    emit bindingChanged(m_binding);
}

void HotkeyEdit::keyPressEvent(QKeyEvent* event) {
    if (!m_capturing) {
        QLineEdit::keyPressEvent(event);
        return;
    }

    int key = event->key();

    // Escape cancels capture
    if (key == Qt::Key_Escape) {
        stopCapture();
        return;
    }

    // Track modifier keys
    if (isModifierKey(key)) {
        m_capturedModifiers = event->modifiers();
        setText(QKeySequence(static_cast<int>(m_capturedModifiers)).toString() + "...");
        return;
    }

    // Non-modifier key pressed - complete the binding
    if (m_capturedModifiers != Qt::NoModifier) {
        HotkeyBinding newBinding;
        newBinding.key = static_cast<Qt::Key>(key);
        newBinding.modifiers = m_capturedModifiers;

        setBinding(newBinding);
        stopCapture();
    }

    event->accept();
}

void HotkeyEdit::keyReleaseEvent(QKeyEvent* event) {
    if (m_capturing && isModifierKey(event->key())) {
        m_capturedModifiers = event->modifiers();
        if (m_capturedModifiers == Qt::NoModifier) {
            setText(tr("Press shortcut..."));
        }
    }
    QLineEdit::keyReleaseEvent(event);
}

void HotkeyEdit::focusInEvent(QFocusEvent* event) {
    QLineEdit::focusInEvent(event);
    startCapture();
}

void HotkeyEdit::focusOutEvent(QFocusEvent* event) {
    stopCapture();
    QLineEdit::focusOutEvent(event);
}

void HotkeyEdit::mousePressEvent(QMouseEvent* event) {
    QLineEdit::mousePressEvent(event);
    startCapture();
}

void HotkeyEdit::startCapture() {
    if (m_capturing) return;

    m_capturing = true;
    setProperty("capturing", true);
    style()->unpolish(this);
    style()->polish(this);
    m_capturedModifiers = Qt::NoModifier;
    setText(tr("Press shortcut..."));
}

void HotkeyEdit::stopCapture() {
    m_capturing = false;
    setProperty("capturing", false);
    style()->unpolish(this);
    style()->polish(this);
    m_capturedModifiers = Qt::NoModifier;
    updateDisplay();
}

void HotkeyEdit::updateDisplay() {
    if (m_binding.key == Qt::Key_unknown) {
        setText(tr("None"));
    } else {
        setText(m_binding.toDisplayString());
    }
}

bool HotkeyEdit::isModifierKey(int key) const {
    return key == Qt::Key_Control ||
           key == Qt::Key_Shift ||
           key == Qt::Key_Alt ||
           key == Qt::Key_Meta ||
           key == Qt::Key_AltGr;
}

} // namespace jules
