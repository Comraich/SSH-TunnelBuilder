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

struct ConnectionRow: View {
    /// Take only the field the row renders, so the row invalidates when the
    /// name changes rather than on any change to the whole `connectionInfo`.
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .background(isSelected ? Color.blue.opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
