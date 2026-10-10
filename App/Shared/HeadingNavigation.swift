import Foundation

/// Picks the heading a Previous / Next Heading command should land on.
/// `current` is the 0-based source line at the top of the viewport (the same line the
/// outline uses to mark the section you're in).
enum HeadingNavigation {
    /// Previous snaps to the current section's heading when you're below it, then walks
    /// upward. Next walks to the first heading strictly below `current`.
    static func targetLine(in headingLines: [Int], current: Int, delta: Int) -> Int? {
        guard !headingLines.isEmpty else { return nil }
        if delta > 0 {
            return headingLines.first(where: { $0 > current }) ?? headingLines.last
        }
        if let here = headingLines.last(where: { $0 <= current }), here < current {
            return here
        }
        return headingLines.last(where: { $0 < current }) ?? headingLines.first
    }
}
