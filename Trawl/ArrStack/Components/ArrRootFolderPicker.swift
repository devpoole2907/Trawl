import SwiftUI

struct ArrRootFolderPicker: View {
    @Binding var selection: String?
    let folders: [ArrRootFolder]
    
    var body: some View {
        Picker("Root Folder", selection: $selection) {
            ForEach(folders, id: \.path) { folder in
                let freeLabel = folder.freeSpace.map { " · " + ByteFormatter.formatRounded(bytes: $0) + " free" } ?? ""
                Text(folder.path + freeLabel)
                    .tag(Optional(folder.path))
            }
        }
    }
}
