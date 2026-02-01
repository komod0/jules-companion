#pragma once

#include <QLineEdit>
#include "input/global_hotkey.h"

namespace jules {

class HotkeyEdit : public QLineEdit {
    Q_OBJECT
    Q_PROPERTY(HotkeyBinding binding READ binding WRITE setBinding NOTIFY bindingChanged)

public:
    explicit HotkeyEdit(QWidget* parent = nullptr);
    ~HotkeyEdit() override = default;

    HotkeyBinding binding() const;
    void setBinding(const HotkeyBinding& binding);

    void clear();

signals:
    void bindingChanged(const HotkeyBinding& binding);

protected:
    void keyPressEvent(QKeyEvent* event) override;
    void keyReleaseEvent(QKeyEvent* event) override;
    void focusInEvent(QFocusEvent* event) override;
    void focusOutEvent(QFocusEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;

private:
    void startCapture();
    void stopCapture();
    void updateDisplay();
    bool isModifierKey(int key) const;

    HotkeyBinding m_binding;
    bool m_capturing = false;
    Qt::KeyboardModifiers m_capturedModifiers = Qt::NoModifier;
};

} // namespace jules
