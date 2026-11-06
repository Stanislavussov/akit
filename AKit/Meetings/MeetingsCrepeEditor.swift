import MeetingsCore
import MeetingsUI
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
                                   if message.type == "save", let key = message.body["key"] as? String, let text = message.body["text"] as? String {
                                       save(key, text)
                                   }
                               },
                               onUnsaved: { key, text in save(key, text) })
        )
    }
}
