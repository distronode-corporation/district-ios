/// Workspace settings: Knowledge.
///
/// ⚠️ `root` IS ANDROID'S (`KnowledgeScreen.kt`), copied verbatim. `readFile` and
/// `fileRefusal` are new: Android has no "Read a text file" yet, and Windows names its
/// controls by their words.
extension A11yID {
    enum Knowledge {
        static let root = "district-knowledge-root"
        static let readFile = "district-knowledge-read-file"
        static let fileRefusal = "district-knowledge-file-refusal"
    }
}
