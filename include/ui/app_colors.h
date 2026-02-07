#pragma once

#include <QColor>
#include <QPalette>
#include "data/settings_manager.h"

namespace jules {

/**
 * ThemeColors - Complete color set for a single theme preset.
 */
struct ThemeColors {
    QColor background;
    QColor backgroundSecondary;
    QColor backgroundDark;
    QColor textPrimary;
    QColor textSecondary;
    QColor accent;
    QColor accentLight;
    QColor separator;
    bool isDark;
};

/**
 * AppColors - Centralized color definitions matching macOS AppColors.swift
 *
 * Provides consistent theming across the application with support for
 * both light and dark modes, plus additional theme presets.
 */
class AppColors {
public:
    // MARK: - Theme Colors Infrastructure

    /// Get ThemeColors for a given Theme enum value
    static ThemeColors colorsForTheme(Theme theme) {
        switch (theme) {
            case Theme::Light:
                return { QColor("#FFFFFF"), QColor("#F5F5F7"), QColor("#E8E8ED"),
                         QColor("#1D1D1F"), QColor("#6E6E73"),
                         QColor("#7B61FF"), QColor("#A78BFF"),
                         QColor("#D1D1D6"), false };
            case Theme::SolarizedDark:
                return { QColor("#002B36"), QColor("#073642"), QColor("#001E27"),
                         QColor("#839496"), QColor("#586E75"),
                         QColor("#268BD2"), QColor("#2AA198"),
                         QColor("#073642"), true };
            case Theme::Dracula:
                return { QColor("#282A36"), QColor("#343746"), QColor("#21222C"),
                         QColor("#F8F8F2"), QColor("#6272A4"),
                         QColor("#BD93F9"), QColor("#FF79C6"),
                         QColor("#44475A"), true };
            case Theme::Nord:
                return { QColor("#2E3440"), QColor("#3B4252"), QColor("#242933"),
                         QColor("#ECEFF4"), QColor("#D8DEE9"),
                         QColor("#88C0D0"), QColor("#81A1C1"),
                         QColor("#4C566A"), true };
            case Theme::Monokai:
                return { QColor("#272822"), QColor("#3E3D32"), QColor("#1E1F1A"),
                         QColor("#F8F8F2"), QColor("#75715E"),
                         QColor("#A6E22E"), QColor("#FD971F"),
                         QColor("#49483E"), true };
            case Theme::OneDark:
                return { QColor("#282C34"), QColor("#2C313A"), QColor("#21252B"),
                         QColor("#ABB2BF"), QColor("#5C6370"),
                         QColor("#61AFEF"), QColor("#C678DD"),
                         QColor("#3E4451"), true };
            case Theme::Dark:
            default:
                return { QColor("#202124"), QColor("#2C2D30"), QColor("#16161A"),
                         QColor("#F0F0F0"), QColor("#7A7384"),
                         QColor("#B2A3FF"), QColor("#CEC4FF"),
                         QColor("#333333"), true };
        }
    }

    /// Set the current application theme (caches the color struct)
    static void setCurrentTheme(Theme theme) {
        s_currentTheme = theme;
        s_cachedColors = colorsForTheme(theme);
    }

    /// Get colors for the current theme (returns cached copy — fast)
    static const ThemeColors& currentColors() {
        return s_cachedColors;
    }

    // MARK: - Base Theme Colors (delegate to current theme)

    /// Main background color
    static QColor background(bool /*dark*/) {
        return currentColors().background;
    }

    /// Secondary background for cards/sections
    static QColor backgroundSecondary(bool /*dark*/) {
        return currentColors().backgroundSecondary;
    }

    /// Darker background for contrast areas
    static QColor backgroundDark(bool /*dark*/) {
        return currentColors().backgroundDark;
    }

    /// Primary text color
    static QColor textPrimary(bool /*dark*/) {
        return currentColors().textPrimary;
    }

    /// Secondary/muted text color
    static QColor textSecondary(bool /*dark*/) {
        return currentColors().textSecondary;
    }

    /// Primary accent color
    static QColor accent(bool /*dark*/) {
        return currentColors().accent;
    }

    /// Light accent variant
    static QColor accentLight(bool /*dark*/) {
        return currentColors().accentLight;
    }

    /// Button text color
    static QColor buttonText(bool /*dark*/) {
        return currentColors().isDark ? QColor(0x00, 0x00, 0x00) : QColor(0xFF, 0xFF, 0xFF);
    }

    /// Button background color
    static QColor buttonBackground(bool /*dark*/) {
        return currentColors().isDark ? QColor(0xFF, 0xFF, 0xFF) : QColor(0x16, 0x16, 0x1A);
    }

    // MARK: - Status Colors (use current theme's isDark for dark/light variant)

    /// Destructive/Failed status (red)
    static QColor destructive(bool /*dark*/) {
        return currentColors().isDark ? QColor(0xFF, 0x67, 0x67) : QColor(0xE5, 0x39, 0x35);
    }

    /// Warning status (orange)
    static QColor warning(bool /*dark*/) {
        return currentColors().isDark ? QColor(0xFF, 0x95, 0x4D) : QColor(0xF5, 0x7C, 0x00);
    }

    /// Review/Paused status (purple - same as accent)
    static QColor review(bool /*dark*/) {
        return accent(false);
    }

    /// Running/Active status (green)
    static QColor running(bool /*dark*/) {
        return currentColors().isDark ? QColor(0x80, 0xF7, 0x96) : QColor(0x43, 0xA0, 0x47);
    }

    /// Starting status (green - same as running)
    static QColor starting(bool /*dark*/) {
        return running(false);
    }

    /// Finished/Completed status (gray)
    static QColor finished(bool /*dark*/) {
        return currentColors().isDark ? QColor(0x7A, 0x73, 0x84) : QColor(0x9E, 0x9E, 0x9E);
    }

    /// Unknown status (gray - same as finished)
    static QColor unknown(bool /*dark*/) {
        return finished(false);
    }

    // MARK: - Session State Colors (convenience methods)

    /// Get color for session state badge
    static QColor stateColor(int state, bool /*dark*/) {
        switch (state) {
            case 2: // Planning
            case 3: // InProgress
                return running(false);
            case 4: // Completed
            case 5: // CompletedUnknown
                return finished(false);
            case 6: // Failed
                return destructive(false);
            case 7: // Paused
                return warning(false);
            case 8: // AwaitingUserFeedback
            case 9: // AwaitingPlanApproval
                return accent(false);
            default: // Unspecified, Queued
                return unknown(false);
        }
    }

    // MARK: - Selection Colors

    /// Selected item background (accent with opacity)
    static QColor selectionBackground(bool /*dark*/) {
        QColor color = accent(false);
        color.setAlphaF(0.2);
        return color;
    }

    /// Hover item background
    static QColor hoverBackground(bool /*dark*/) {
        QColor color = backgroundSecondary(false);
        color.setAlphaF(0.9);
        return color;
    }

    // MARK: - Separator/Border Colors

    /// Separator line color
    static QColor separator(bool /*dark*/) {
        return currentColors().separator;
    }

    // MARK: - Diff Colors

    /// Lines added indicator (green)
    static QColor linesAdded(bool /*dark*/) {
        return currentColors().isDark ? QColor(0x80, 0xF7, 0x96) : QColor(0x13, 0x99, 0x16);
    }

    /// Lines removed indicator (red)
    static QColor linesRemoved(bool /*dark*/) {
        return currentColors().isDark ? QColor(0xFF, 0x67, 0x67) : QColor(0xFF, 0x10, 0x08);
    }

    // MARK: - Unviewed Indicator

    /// Unviewed session indicator dot color
    static QColor unviewedIndicator(bool /*dark*/) {
        return accent(false);
    }

private:
    // NOTE: Not thread-safe. Must only be called from the GUI thread.
    static inline Theme s_currentTheme = Theme::Dark;
    static inline ThemeColors s_cachedColors = colorsForTheme(Theme::Dark);
};

} // namespace jules
