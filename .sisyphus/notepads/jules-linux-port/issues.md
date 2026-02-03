# Issues & Gotchas - Jules Linux Port

**Project Status**: COMPLETE (2026-02-03)

## Known Challenges (All Addressed)
- OpenGL 4.3+ required for compute shaders (Boids animation) - **Implemented with fallback**
- Wayland global hotkeys restricted by security model - **xdg-desktop-portal integration**
- System tray support varies across DEs (GNOME needs extension) - **Graceful fallback**

## Key Technical Learnings
See `learnings.md` for detailed technical documentation of implementation patterns.
