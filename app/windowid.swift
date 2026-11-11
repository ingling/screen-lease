// windowid: list CGWindowIDs of an app's on-screen windows, for `screencapture -l <id>`,
// which captures that window even when other windows cover it (no need to bring it to the front).
// usage: windowid <app name substring>      -> "id<TAB>WxH<TAB>title", largest window first
// Window titles need Screen Recording permission for the calling process; ids do not.
// Build: swiftc -O -o windowid windowid.swift

import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: windowid <app name substring>\n".data(using: .utf8)!)
    exit(1)
}
let needle = args[1].lowercased()
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]) ?? []
var rows: [(Int, Double, String)] = []
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String ?? "")
    guard owner.lowercased().contains(needle), (w[kCGWindowLayer as String] as? Int ?? 1) == 0 else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let wd = b["Width"] ?? 0, ht = b["Height"] ?? 0
    let title = w[kCGWindowName as String] as? String ?? ""
    rows.append((id, wd * ht, "\(id)\t\(Int(wd))x\(Int(ht))\t\(title)"))
}
if rows.isEmpty { exit(2) }
for r in rows.sorted(by: { $0.1 > $1.1 }) { print(r.2) }
