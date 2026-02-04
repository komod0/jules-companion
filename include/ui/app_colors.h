#pragma once

#include <QColor>
#include <QPalette>

namespace jules {

/**
 * AppColors - Centralized color definitions matching macOS AppColors.swift
 * 
 * Provides consistent theming across the application with support for
 * both light and dark modes.
 */
class AppColors {
public:
    // MARK: - Base Theme Colors
    
    /// Main background color
    static QColor background(bool dark) {
        return dark ? QColor(0x20, 0x21, 0x24)    // #202124
                    : QColor(0xFF, 0xFF, 0xFF);   // #FFFFFF
    }
    
    /// Secondary background for cards/sections
    static QColor backgroundSecondary(bool dark) {
        return dark ? QColor(0x2C, 0x2D, 0x30)    // #2C2D30
                    : QColor(0xF5, 0xF5, 0xF7);   // #F5F5F7
    }
    
    /// Darker background for contrast areas
    static QColor backgroundDark(bool dark) {
        return dark ? QColor(0x16, 0x16, 0x1A)    // #16161A
                    : QColor(0xE8, 0xE8, 0xED);   // #E8E8ED
    }
    
    /// Primary text color
    static QColor textPrimary(bool dark) {
        return dark ? QColor(0xFF, 0xFF, 0xFF)    // White
                    : QColor(0x1D, 0x1D, 0x1F);   // #1D1D1F
    }
    
    /// Secondary/muted text color
    static QColor textSecondary(bool dark) {
        return dark ? QColor(0x7A, 0x73, 0x84)    // #7A7384
                    : QColor(0x6E, 0x6E, 0x73);   // #6E6E73
    }
    
    /// Primary accent color (purple)
    static QColor accent(bool dark) {
        return dark ? QColor(0xB2, 0xA3, 0xFF)    // #B2A3FF - lighter purple
                    : QColor(0x7B, 0x61, 0xFF);   // #7B61FF - deeper purple
    }
    
    /// Light accent variant
    static QColor accentLight(bool dark) {
        return dark ? QColor(0xCE, 0xC4, 0xFF)    // #CEC4FF
                    : QColor(0xA7, 0x8B, 0xFF);   // #A78BFF
    }
    
    /// Button text color
    static QColor buttonText(bool dark) {
        return dark ? QColor(0x00, 0x00, 0x00)    // Black
                    : QColor(0xFF, 0xFF, 0xFF);   // White
    }
    
    /// Button background color
    static QColor buttonBackground(bool dark) {
        return dark ? QColor(0xFF, 0xFF, 0xFF)    // White
                    : QColor(0x16, 0x16, 0x1A);   // #16161A
    }
    
    // MARK: - Status Colors
    
    /// Destructive/Failed status (red)
    static QColor destructive(bool dark) {
        return dark ? QColor(0xFF, 0x67, 0x67)    // #FF6767
                    : QColor(0xE5, 0x39, 0x35);   // #E53935
    }
    
    /// Warning status (orange)
    static QColor warning(bool dark) {
        return dark ? QColor(0xFF, 0x95, 0x4D)    // #FF954D
                    : QColor(0xF5, 0x7C, 0x00);   // #F57C00
    }
    
    /// Review/Paused status (purple - same as accent)
    static QColor review(bool dark) {
        return accent(dark);
    }
    
    /// Running/Active status (green)
    static QColor running(bool dark) {
        return dark ? QColor(0x80, 0xF7, 0x96)    // #80F796
                    : QColor(0x43, 0xA0, 0x47);   // #43A047
    }
    
    /// Starting status (green - same as running)
    static QColor starting(bool dark) {
        return running(dark);
    }
    
    /// Finished/Completed status (gray)
    static QColor finished(bool dark) {
        return dark ? QColor(0x7A, 0x73, 0x84)    // #7A7384
                    : QColor(0x9E, 0x9E, 0x9E);   // #9E9E9E
    }
    
    /// Unknown status (gray - same as finished)
    static QColor unknown(bool dark) {
        return finished(dark);
    }
    
    // MARK: - Session State Colors (convenience methods)
    
    /// Get color for session state badge
    static QColor stateColor(int state, bool dark) {
        // SessionState enum values:
        // 0=Unspecified, 1=Queued, 2=Planning, 3=InProgress, 4=Completed,
        // 5=CompletedUnknown, 6=Failed, 7=Paused, 8=AwaitingUserFeedback, 9=AwaitingPlanApproval
        switch (state) {
            case 2: // Planning
            case 3: // InProgress
                return running(dark);
            case 4: // Completed
            case 5: // CompletedUnknown
                return finished(dark);
            case 6: // Failed
                return destructive(dark);
            case 7: // Paused
                return warning(dark);
            case 8: // AwaitingUserFeedback
            case 9: // AwaitingPlanApproval
                return accent(dark);
            default: // Unspecified, Queued
                return unknown(dark);
        }
    }
    
    // MARK: - Selection Colors
    
    /// Selected item background (accent with opacity)
    static QColor selectionBackground(bool dark) {
        QColor color = accent(dark);
        color.setAlphaF(0.2);
        return color;
    }
    
    /// Hover item background
    static QColor hoverBackground(bool dark) {
        QColor color = backgroundSecondary(dark);
        color.setAlphaF(0.9);
        return color;
    }
    
    // MARK: - Separator/Border Colors
    
    /// Separator line color
    static QColor separator(bool dark) {
        return dark ? QColor(0x33, 0x33, 0x33)    // #333333
                    : QColor(0xD1, 0xD1, 0xD6);   // #D1D1D6
    }
    
    // MARK: - Diff Colors
    
    /// Lines added indicator (green)
    static QColor linesAdded(bool dark) {
        return dark ? QColor(0x80, 0xF7, 0x96)    // #80F796
                    : QColor(0x13, 0x99, 0x16);   // #139916
    }
    
    /// Lines removed indicator (red)
    static QColor linesRemoved(bool dark) {
        return dark ? QColor(0xFF, 0x67, 0x67)    // #FF6767
                    : QColor(0xFF, 0x10, 0x08);   // #FF1008
    }
    
    // MARK: - Unviewed Indicator
    
    /// Unviewed session indicator dot color
    static QColor unviewedIndicator(bool dark) {
        return accent(dark);
    }
};

} // namespace jules
