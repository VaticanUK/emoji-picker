#!/usr/bin/env swift
// Generates Sources/PickerCore/Resources/emoji.json from Unicode and CLDR data.
//
// Usage:
//   swift Scripts/generate-emoji.swift <emoji-test.txt> <annotations.json> [<annotationsDerived.json>] > Sources/PickerCore/Resources/emoji.json
//
// Sources used for the committed emoji.json (Unicode License v3, redistribution allowed):
//   - https://unicode.org/Public/emoji/latest/emoji-test.txt   (Emoji 18.0, file dated 2026-04-30)
//   - https://raw.githubusercontent.com/unicode-org/cldr-json/49.0.0/cldr-json/cldr-annotations-full/annotations/en/annotations.json
//   - https://raw.githubusercontent.com/unicode-org/cldr-json/49.0.0/cldr-json/cldr-annotations-derived-full/annotationsDerived/en/annotations.json
//   (cldr-json release tag 49.0.0)
//
// Output: JSON array of {"e": emoji, "n": name, "k": [keywords], "c": category, "v": [5 skin tones]?}
// Only fully-qualified lines are kept. Skin-tone lines fold into their base's "v" when exactly
// five single-tone variants exist; all other toned lines are dropped. The Component group is skipped.

import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: generate-emoji.swift <emoji-test> <annotations> [<derived>]\n".utf8))
    exit(2)
}

func stripFE0F(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value != 0xFE0F }))
}

func loadKeywords(_ path: String, _ outer: String, into table: inout [String: [String]]) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let a = (root[outer] as? [String: Any])?["annotations"] as? [String: Any] else {
        fatalError("unexpected shape in \(path)")
    }
    for (key, value) in a {
        guard let d = value as? [String: Any], let words = d["default"] as? [String] else { continue }
        table[stripFE0F(key)] = words
    }
}

var keywords: [String: [String]] = [:]
try loadKeywords(args[2], "annotations", into: &keywords)
if args.count >= 4 { try loadKeywords(args[3], "annotationsDerived", into: &keywords) }

let groupMap: [String: String] = [
    "Smileys & Emotion": "smileys", "People & Body": "people", "Animals & Nature": "animals",
    "Food & Drink": "food", "Travel & Places": "travel", "Activities": "activities",
    "Objects": "objects", "Symbols": "symbols", "Flags": "flags",
]

struct Entry { var e: String; var n: String; var c: String; var v: [String]? }

let toneRange: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
func tones(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value).filter { toneRange.contains($0) } }
func untoned(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !toneRange.contains($0.value) }))
}

var entries: [Entry] = []
var indexByKey: [String: Int] = [:]
var toned: [(base: String, tone: UInt32, emoji: String)] = []
var group: String? = nil

let text = try String(contentsOfFile: args[1], encoding: .utf8)
for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
    if line.hasPrefix("# group: ") { group = String(line.dropFirst(9)); continue }
    guard let g = group, let cat = groupMap[g], !line.hasPrefix("#"),
          let semi = line.firstIndex(of: ";") else { continue }
    let rest = line[line.index(after: semi)...]
    guard rest.drop(while: { $0 == " " }).hasPrefix("fully-qualified"),
          let hash = rest.firstIndex(of: "#") else { continue }
    // "# 👍 E0.6 thumbs up": emoji, version, name
    let parts = rest[rest.index(after: hash)...].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count == 3 else { continue }
    let emoji = String(parts[0])
    var name = String(parts[2])
    let t = tones(emoji)
    if !t.isEmpty {
        if Set(t).count == 1 { toned.append((stripFE0F(untoned(emoji)), t[0], emoji)) }
        continue
    }
    name = name.trimmingCharacters(in: .whitespaces)
    indexByKey[stripFE0F(emoji)] = entries.count
    entries.append(Entry(e: emoji, n: name, c: cat, v: nil))
}

var byBase: [String: [UInt32: String]] = [:]
for t in toned { byBase[t.base, default: [:]][t.tone] = t.emoji }
for (base, variants) in byBase where variants.count == 5 {
    guard let i = indexByKey[base] else { continue }
    entries[i].v = toneRange.map { variants[$0]! }
}

var out: [[String: Any]] = []
for en in entries {
    var d: [String: Any] = ["e": en.e, "n": en.n, "c": en.c, "k": keywords[stripFE0F(en.e)] ?? []]
    if let v = en.v { d["v"] = v }
    out.append(d)
}
let json = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
