import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdown = UTType(exportedAs: "net.daringfireball.markdown")
}

struct MarkdownDocument: FileDocument {
    var text: String

    init(text: String = "") { self.text = text }

    static var readableContentTypes: [UTType] { [.markdown, .plainText] }
    static var writableContentTypes: [UTType] { [.markdown] }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
