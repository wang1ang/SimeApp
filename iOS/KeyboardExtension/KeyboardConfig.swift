/// Keyboard behavior switches kept in one place for device experiments.
/// Keep production defaults conservative; change a flag here instead of editing
/// event-handling code.
enum KeyboardConfig {
    /// Process letters on touch-down instead of touch-up.
    static let processLettersOnTouchDown = false

    /// Allow overlapping touches on the keyboard and its keys.
    static let enableMultipleTouch = true
}
