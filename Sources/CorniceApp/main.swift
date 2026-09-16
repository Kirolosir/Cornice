import AppKit
import CorniceKit

// Entry point.
//
// AppKit rather than a SwiftUI `App`: this application has no windows in the
// ordinary sense — its entire interface is one borderless panel pinned to the
// top of the screen — and `NSApplicationMain` gives direct control over
// activation policy, the status item, and termination. A SwiftUI `App` would
// mean fighting its window management to end up in the same place.

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
// `.accessory`: no Dock icon and no menu bar of its own, but still able to show
// windows and become active when the settings window or a file picker needs it.
// `.prohibited` would block those outright.
application.setActivationPolicy(.accessory)
application.run()
