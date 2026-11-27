/// ASCII emoticons and the emoji each one stands for, so typing `:)` in the search finds 🙂.
public enum Emoticons {
    /// Keys are lowercase; lookups lowercase the query, so `:P` and `:p` are the same.
    public static let table: [String: String] = {
        var t: [String: String] = [:]
        // Eyes then mouth, which people also type with a `-` nose: `:)` and `:-)`.
        let faces: [(String, String)] = [
            (":)", "🙂"), ("=)", "🙂"), (":(", "🙁"), ("=(", "🙁"),
            (";)", "😉"), (":d", "😃"), ("=d", "😃"), (";d", "😉"),
            (":p", "😛"), ("=p", "😛"), (";p", "😜"), ("xp", "😝"),
            (":o", "😮"), (":|", "😐"), (":/", "😕"), (":\\", "😕"),
            (":*", "😘"), (":s", "😖"), (":x", "🤐"), (":$", "😳"),
            (":@", "😡"), ("8)", "😎"), ("b)", "😎"), (":]", "🙂"), (":[", "🙁"),
        ]
        for (face, emoji) in faces {
            t[face] = emoji
            t[String(face.first!) + "-" + String(face.dropFirst())] = emoji
        }
        let others: [(String, String)] = [
            ("xd", "😆"), (":')", "🥲"), (":'(", "😢"), (":'-(", "😢"),
            (">:(", "😠"), (">:-(", "😠"), ("o:)", "😇"), ("o:-)", "😇"),
            (">:)", "😈"), (">:-)", "😈"), ("<3", "❤️"), ("</3", "💔"),
            ("^_^", "😊"), ("^^", "😊"), ("-_-", "😑"), ("t_t", "😭"),
            ("o_o", "😳"), ("o.o", "😳"), (":3", "😺"),
        ]
        for (face, emoji) in others { t[face] = emoji }
        return t
    }()

    /// The emoji for an emoticon, ignoring case and surrounding spaces.
    public static func emoji(for query: String) -> String? {
        table[query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
