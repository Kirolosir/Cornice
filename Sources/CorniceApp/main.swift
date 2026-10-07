import AppKit
import CorniceKit

// AppKit entry point for the panel, menu bar item and app lifecycle.

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
// Hide the Dock icon but still allow settings and file pickers to open and receive focus.
application.setActivationPolicy(.accessory)
application.run()
