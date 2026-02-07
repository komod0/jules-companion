#include <gtest/gtest.h>
#include <QApplication>

#include "ui/app_colors.h"
#include "data/settings_manager.h"

namespace jules {
namespace test {

class AppColorsTest : public ::testing::Test {
protected:
    void TearDown() override {
        // Reset to default theme after each test
        AppColors::setCurrentTheme(Theme::Dark);
    }
};

// ============================================================================
// Theme Preset Color Tests
// ============================================================================

TEST_F(AppColorsTest, DarkThemeIsDark) {
    auto colors = AppColors::colorsForTheme(Theme::Dark);
    EXPECT_TRUE(colors.isDark);
}

TEST_F(AppColorsTest, LightThemeIsNotDark) {
    auto colors = AppColors::colorsForTheme(Theme::Light);
    EXPECT_FALSE(colors.isDark);
}

TEST_F(AppColorsTest, AllNamedDarkThemesAreDark) {
    const std::vector<Theme> darkThemes = {
        Theme::Dark, Theme::SolarizedDark, Theme::Dracula,
        Theme::Nord, Theme::Monokai, Theme::OneDark
    };

    for (auto theme : darkThemes) {
        auto colors = AppColors::colorsForTheme(theme);
        EXPECT_TRUE(colors.isDark)
            << "Theme " << static_cast<int>(theme) << " should be dark";
    }
}

TEST_F(AppColorsTest, AllThemesHaveValidColors) {
    // Every theme preset should return non-default QColor values
    const std::vector<Theme> allThemes = {
        Theme::Light, Theme::Dark, Theme::SolarizedDark,
        Theme::Dracula, Theme::Nord, Theme::Monokai, Theme::OneDark
    };

    for (auto theme : allThemes) {
        auto colors = AppColors::colorsForTheme(theme);
        EXPECT_TRUE(colors.background.isValid())
            << "Theme " << static_cast<int>(theme) << " background invalid";
        EXPECT_TRUE(colors.backgroundSecondary.isValid())
            << "Theme " << static_cast<int>(theme) << " backgroundSecondary invalid";
        EXPECT_TRUE(colors.textPrimary.isValid())
            << "Theme " << static_cast<int>(theme) << " textPrimary invalid";
        EXPECT_TRUE(colors.textSecondary.isValid())
            << "Theme " << static_cast<int>(theme) << " textSecondary invalid";
        EXPECT_TRUE(colors.accent.isValid())
            << "Theme " << static_cast<int>(theme) << " accent invalid";
        EXPECT_TRUE(colors.separator.isValid())
            << "Theme " << static_cast<int>(theme) << " separator invalid";
    }
}

TEST_F(AppColorsTest, DarkThemeHasDarkBackground) {
    auto colors = AppColors::colorsForTheme(Theme::Dark);
    EXPECT_LT(colors.background.lightnessF(), 0.3);
}

TEST_F(AppColorsTest, LightThemeHasLightBackground) {
    auto colors = AppColors::colorsForTheme(Theme::Light);
    EXPECT_GT(colors.background.lightnessF(), 0.7);
}

// ============================================================================
// Static Cache Tests
//
// The cache was added to fix a performance regression where currentColors()
// called colorsForTheme() (constructing 8 QColors from hex) on every call.
// Now it's cached — setCurrentTheme() updates the cache.
// ============================================================================

TEST_F(AppColorsTest, SetCurrentThemeUpdatesCachedColors) {
    AppColors::setCurrentTheme(Theme::Dark);
    auto darkColors = AppColors::currentColors();
    EXPECT_TRUE(darkColors.isDark);

    AppColors::setCurrentTheme(Theme::Light);
    auto lightColors = AppColors::currentColors();
    EXPECT_FALSE(lightColors.isDark);
    EXPECT_NE(darkColors.background, lightColors.background);
}

TEST_F(AppColorsTest, CachedColorsMatchForTheme) {
    const std::vector<Theme> allThemes = {
        Theme::Light, Theme::Dark, Theme::SolarizedDark,
        Theme::Dracula, Theme::Nord, Theme::Monokai, Theme::OneDark
    };

    for (auto theme : allThemes) {
        AppColors::setCurrentTheme(theme);
        auto cached = AppColors::currentColors();
        auto fresh = AppColors::colorsForTheme(theme);

        EXPECT_EQ(cached.background, fresh.background)
            << "Theme " << static_cast<int>(theme) << " background mismatch";
        EXPECT_EQ(cached.textPrimary, fresh.textPrimary)
            << "Theme " << static_cast<int>(theme) << " textPrimary mismatch";
        EXPECT_EQ(cached.accent, fresh.accent)
            << "Theme " << static_cast<int>(theme) << " accent mismatch";
        EXPECT_EQ(cached.isDark, fresh.isDark)
            << "Theme " << static_cast<int>(theme) << " isDark mismatch";
    }
}

TEST_F(AppColorsTest, CurrentColorsReturnsByConstRef) {
    AppColors::setCurrentTheme(Theme::Dracula);
    const auto& ref1 = AppColors::currentColors();
    const auto& ref2 = AppColors::currentColors();
    // Both should point to the same cached object
    EXPECT_EQ(&ref1, &ref2);
}

// ============================================================================
// Delegate Method Tests
//
// All AppColors::xxx(bool) methods should delegate to the cached theme,
// not use the bool dark parameter (which is ignored).
// ============================================================================

TEST_F(AppColorsTest, BackgroundDelegatesToCurrentTheme) {
    AppColors::setCurrentTheme(Theme::Dracula);
    QColor bg = AppColors::background(false); // bool is ignored
    auto draculaColors = AppColors::colorsForTheme(Theme::Dracula);
    EXPECT_EQ(bg, draculaColors.background);
}

TEST_F(AppColorsTest, TextPrimaryDelegatesToCurrentTheme) {
    AppColors::setCurrentTheme(Theme::Nord);
    QColor text = AppColors::textPrimary(true); // bool is ignored
    auto nordColors = AppColors::colorsForTheme(Theme::Nord);
    EXPECT_EQ(text, nordColors.textPrimary);
}

TEST_F(AppColorsTest, AccentDelegatesToCurrentTheme) {
    AppColors::setCurrentTheme(Theme::Monokai);
    QColor accent = AppColors::accent(false);
    auto monokaiColors = AppColors::colorsForTheme(Theme::Monokai);
    EXPECT_EQ(accent, monokaiColors.accent);
}

TEST_F(AppColorsTest, SeparatorDelegatesToCurrentTheme) {
    AppColors::setCurrentTheme(Theme::OneDark);
    QColor sep = AppColors::separator(true);
    auto oneDarkColors = AppColors::colorsForTheme(Theme::OneDark);
    EXPECT_EQ(sep, oneDarkColors.separator);
}

TEST_F(AppColorsTest, BoolParameterIsIgnored) {
    // The bool dark parameter should make no difference
    AppColors::setCurrentTheme(Theme::Dracula);
    EXPECT_EQ(AppColors::background(true), AppColors::background(false));
    EXPECT_EQ(AppColors::textPrimary(true), AppColors::textPrimary(false));
    EXPECT_EQ(AppColors::accent(true), AppColors::accent(false));
    EXPECT_EQ(AppColors::separator(true), AppColors::separator(false));
    EXPECT_EQ(AppColors::backgroundSecondary(true), AppColors::backgroundSecondary(false));
}

// ============================================================================
// Status Color Tests
//
// Status colors (destructive, warning, running, finished) use isDark from
// the current theme, not the bool parameter.
// ============================================================================

TEST_F(AppColorsTest, StatusColorsVaryByThemeDarkness) {
    AppColors::setCurrentTheme(Theme::Dark); // isDark = true
    QColor destructiveDark = AppColors::destructive(false);

    AppColors::setCurrentTheme(Theme::Light); // isDark = false
    QColor destructiveLight = AppColors::destructive(false);

    // Dark and light should use different red tones
    EXPECT_NE(destructiveDark, destructiveLight);
}

TEST_F(AppColorsTest, RunningColorDiffersForDarkAndLight) {
    AppColors::setCurrentTheme(Theme::Dark);
    QColor runDark = AppColors::running(false);

    AppColors::setCurrentTheme(Theme::Light);
    QColor runLight = AppColors::running(false);

    EXPECT_NE(runDark, runLight);
}

// ============================================================================
// Theme Uniqueness Tests
// ============================================================================

TEST_F(AppColorsTest, EachThemeHasUniqueBackground) {
    std::vector<QColor> backgrounds;
    const std::vector<Theme> allThemes = {
        Theme::Light, Theme::Dark, Theme::SolarizedDark,
        Theme::Dracula, Theme::Nord, Theme::Monokai, Theme::OneDark
    };

    for (auto theme : allThemes) {
        auto colors = AppColors::colorsForTheme(theme);
        for (const auto& existing : backgrounds) {
            EXPECT_NE(colors.background, existing)
                << "Theme " << static_cast<int>(theme) << " has duplicate background";
        }
        backgrounds.push_back(colors.background);
    }
}

TEST_F(AppColorsTest, EachThemeHasUniqueAccent) {
    std::vector<QColor> accents;
    const std::vector<Theme> allThemes = {
        Theme::Light, Theme::Dark, Theme::SolarizedDark,
        Theme::Dracula, Theme::Nord, Theme::Monokai, Theme::OneDark
    };

    for (auto theme : allThemes) {
        auto colors = AppColors::colorsForTheme(theme);
        for (const auto& existing : accents) {
            EXPECT_NE(colors.accent, existing)
                << "Theme " << static_cast<int>(theme) << " has duplicate accent";
        }
        accents.push_back(colors.accent);
    }
}

// ============================================================================
// Default Theme Fallback
// ============================================================================

TEST_F(AppColorsTest, SystemThemeFallsThroughToDark) {
    // Theme::System is not in the switch — falls through to default (Dark)
    auto systemColors = AppColors::colorsForTheme(Theme::System);
    auto darkColors = AppColors::colorsForTheme(Theme::Dark);
    EXPECT_EQ(systemColors.background, darkColors.background);
    EXPECT_EQ(systemColors.isDark, darkColors.isDark);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
