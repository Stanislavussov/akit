import MeetingsCore
import MeetingsUI
import AppKit
import SwiftUI

extension MeetingsEditor {
    /// Meetings' Summary and own tabs in AKit (docs/design/meetings.md, M17): the Notebook's
    /// Crepe editor, with pictures in the meeting's `tabs/assets`.
    @MainActor static let crepe = MeetingsEditor { page, save in
        AnyView(
            NotebookEditorView(document: .init(key: page.key, text: page.text, generation: page.generation),
                               imageFile: { MeetingStore.image(in: page.folder, link: $0) },
                               upload: { data, ext in try MeetingStore.saveImage(in: page.folder, data: data, ext: ext) },
                               onMessage: { message in
                                   switch message.type {
                                   case "save":
                                       if let key = message.body["key"] as? String, let text = message.body["text"] as? String { save(key, text) }
                                   case "linkOpen":
                                       // ⌘-click on a link (a ticket Pi put into the summary): web links open in the browser.
                                       if let link = message.body["link"] as? String, let url = URL(string: link),
                                          ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                                           NSWorkspace.shared.open(url)
                                       }
                                   default: break
                                   }
                               },
                               onUnsaved: { key, text in save(key, text) })
        )
    }
}
