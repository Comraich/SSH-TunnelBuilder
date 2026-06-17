// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Encrypted connection-export file (`.sshtunnels`). Declared in the app's
    /// `UTExportedTypeDeclarations` Info.plist entry and conforms to `public.json`
    /// (the on-disk envelope is JSON), so it is both a first-class branded type
    /// and openable by anything that reads JSON.
    static let sshTunnelsExport = UTType(exportedAs: "no.comraich.ssh-tunnelbuilder.export")
}

/// Thin `FileDocument` wrapper used by `.fileExporter`. It carries the already
/// encrypted bytes produced by `ConnectionTransfer.encrypt` — no plaintext and
/// no app state, just the blob to write.
struct EncryptedExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.sshTunnelsExport, .json] }
    static var writableContentTypes: [UTType] { [.sshTunnelsExport] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
