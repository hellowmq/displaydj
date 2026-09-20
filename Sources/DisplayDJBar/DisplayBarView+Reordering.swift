import DisplayDJCore
import SwiftUI

/// Bridges a SwiftUI drop onto a card to the controller's reorder call.
///
/// The dragged card's stable ID travels in the item provider's `NSString`, so the
/// delegate does not need any shared drag-state: it reads the source off the drop and
/// asks the controller to move it into the destination's slot. `EditMode` is unavailable
/// on macOS, so this is the drag primitive the popover's own `isEditing` flag gates.
struct DisplayCardDropDelegate: DropDelegate {
  let controller: DisplayBarController
  let destination: DisplayDescriptor

  func performDrop(info: DropInfo) -> Bool {
    guard let provider = info.itemProviders(for: [.text]).first else { return false }
    provider.loadObject(ofClass: NSString.self) { [self] item, _ in
      guard let sourceID = item as? String else { return }
      let destID = self.destination.stableID ?? ""
      DispatchQueue.main.async {
        self.controller.reorderDisplays(sourceStableID: sourceID, destinationStableID: destID)
      }
    }
    return true
  }
}

extension View {
  /// Attaches drag-to-reorder (`.onDrag` / `.onDrop`) only while editing is active, so the
  /// cards stay ordinary brightness controls the rest of the time. The drag item carries the
  /// source's stable ID; the drop delegate reads it back and reorders.
  @ViewBuilder
  func reordering(
    when active: Bool,
    display: DisplayDescriptor,
    controller: DisplayBarController
  ) -> some View {
    if active {
      self
        .onDrag {
          NSItemProvider(object: NSString(string: display.stableID ?? UUID().uuidString))
        }
        .onDrop(
          of: [.text],
          delegate: DisplayCardDropDelegate(controller: controller, destination: display)
        )
    } else {
      self
    }
  }
}
