import SwiftUI
import SkillboxCore

/// One shared scale instead of every view inventing its own numbers (7, 9, 10, 2, 6…). Four sizes
/// cover everything the app needs: `tight` inside a control, `row` between a row's own lines,
/// `section` between unrelated groups, `page` around a view's edges.
enum Space {
    static let tight: CGFloat = 4
    static let row: CGFloat = 8
    static let section: CGFloat = 12
    static let page: CGFloat = 16
}
