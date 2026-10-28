import Foundation

/// The factory modes shipped with the Dock, as JSON in the same format as user
/// documents (so they double as examples). Users override a factory mode by saving
/// a document with the same id.
public enum DefaultModes {
    /// The mode the engine starts in when no other is configured.
    public static let fallbackModeID: ModeID = .free

    /// Factory modes in display order. Decoding is checked by the test suite; a
    /// malformed seed is a programming error.
    public static let all: [ModeDefinition] = {
        do {
            let documents = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] ?? []
            let migrator = ModeMigrator()
            return try documents.map { document in
                let data = try JSONSerialization.data(withJSONObject: document)
                return try migrator.decode(data).definition
            }
        } catch {
            preconditionFailure("Invalid factory mode seed: \(error)")
        }
    }()

    public static func definition(_ id: ModeID) -> ModeDefinition? {
        all.first { $0.id == id }
    }

    /// The seed, a JSON array of mode documents.
    public static let json = #"""
    [
      {
        "schemaVersion": 1,
        "id": "writing",
        "name": "Writing",
        "symbol": "pencil.line",
        "description": "Long-form writing. Keep editors and notes up front; chat, feeds and video are distractions. Messages wait until the session ends unless they are urgent.",
        "dock": {
          "prioritized": ["com.apple.iWork.Pages", "com.microsoft.Word", "com.ulyssesapp.mac", "pro.writer.mac", "md.obsidian", "com.apple.Notes"],
          "hidden": ["com.apple.Music", "com.spotify.client", "com.apple.TV"]
        },
        "attention": {
          "focus": {
            "categories": ["writing"],
            "apps": ["com.apple.iWork.Pages", "com.microsoft.Word", "com.ulyssesapp.mac", "pro.writer.mac", "md.obsidian", "com.apple.Notes", "abnerworks.Typora", "net.shinyfrog.bear"],
            "urlHosts": ["docs.google.com", "notion.so"]
          },
          "distractions": {
            "categories": ["media", "communication"],
            "urlHosts": ["youtube.com", "x.com", "reddit.com", "news.ycombinator.com"]
          }
        },
        "notifications": {
          "default": "hold",
          "rules": [
            { "match": { "categories": ["promotion", "social"] }, "action": "silence", "note": "Feeds and promotions are not worth an interruption while writing" },
            { "match": { "categories": ["chat"] }, "action": "summarize", "note": "Group chat is summarized after the session" }
          ],
          "alwaysAllow": { "categories": ["calendar"] },
          "urgent": { "keywords": ["urgent", "asap", "outage", "incident"], "honorTimeSensitive": true },
          "allowFromFocusedApp": true
        },
        "transitions": [
          { "trigger": "activity", "match": { "categories": ["writing"] }, "forSeconds": 300 }
        ]
      },
      {
        "schemaVersion": 1,
        "id": "building",
        "name": "Building",
        "symbol": "hammer",
        "description": "Programming and shipping. IDEs, terminals and code hosting are on task; build and CI results come through, chat is summarized and everything else waits.",
        "dock": {
          "prioritized": ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"],
          "hidden": ["com.apple.Music", "com.spotify.client", "com.apple.TV"]
        },
        "attention": {
          "focus": {
            "categories": ["code"],
            "apps": ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.jetbrains.*", "dev.zed.Zed"],
            "urlHosts": ["github.com", "gitlab.com", "stackoverflow.com", "developer.apple.com", "swift.org"]
          },
          "distractions": {
            "categories": ["media"],
            "urlHosts": ["youtube.com", "x.com", "reddit.com"]
          }
        },
        "notifications": {
          "default": "hold",
          "rules": [
            { "match": { "categories": ["build"] }, "action": "allow", "note": "Build and CI results are part of the work" },
            { "match": { "categories": ["promotion", "social"] }, "action": "silence" },
            { "match": { "categories": ["chat"] }, "action": "summarize" }
          ],
          "alwaysAllow": { "categories": ["calendar"] },
          "urgent": { "keywords": ["urgent", "asap", "outage", "incident", "down"], "honorTimeSensitive": true },
          "allowFromFocusedApp": true
        },
        "transitions": [
          { "trigger": "activity", "match": { "categories": ["code"] }, "forSeconds": 300 }
        ]
      },
      {
        "schemaVersion": 1,
        "id": "reading",
        "name": "Reading",
        "symbol": "book",
        "description": "Reading papers, books and long articles. Readers and PDFs are on task; notifications are summarized for later.",
        "dock": {
          "prioritized": ["com.apple.Preview", "com.apple.iBooksX", "com.readdle.PDFExpert-Mac"]
        },
        "attention": {
          "focus": {
            "apps": ["com.apple.Preview", "com.apple.iBooksX", "com.readdle.PDFExpert-Mac", "com.amazon.Lassen"],
            "titleKeywords": [".pdf", ".epub"]
          },
          "distractions": {
            "categories": ["communication", "media"]
          }
        },
        "notifications": {
          "default": "summarize",
          "rules": [
            { "match": { "categories": ["direct-message"] }, "action": "hold" },
            { "match": { "categories": ["promotion", "social"] }, "action": "silence" }
          ],
          "alwaysAllow": { "categories": ["calendar"] },
          "urgent": { "keywords": ["urgent", "asap"], "honorTimeSensitive": true }
        },
        "transitions": [
          { "trigger": "activity", "match": { "apps": ["com.apple.Preview", "com.apple.iBooksX", "com.readdle.PDFExpert-Mac", "com.amazon.Lassen"], "titleKeywords": [".pdf", ".epub"] }, "forSeconds": 600 }
        ]
      },
      {
        "schemaVersion": 1,
        "id": "meeting",
        "name": "Meeting",
        "symbol": "video",
        "description": "On a call. Only calendar alerts and urgent messages come through; nothing pops up over a shared screen.",
        "dock": {
          "prioritized": ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.apple.iCal"]
        },
        "attention": {
          "focus": {
            "categories": ["meeting"],
            "apps": ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "Cisco-Systems.Spark"],
            "urlHosts": ["meet.google.com", "zoom.us", "teams.microsoft.com"]
          },
          "distractions": {
            "categories": ["media"]
          }
        },
        "notifications": {
          "default": "hold",
          "rules": [
            { "match": { "categories": ["promotion", "social", "system"] }, "action": "silence" },
            { "match": { "categories": ["chat", "email"] }, "action": "summarize" }
          ],
          "alwaysAllow": { "categories": ["calendar"] },
          "urgent": { "keywords": ["urgent", "asap", "outage", "incident"], "honorTimeSensitive": true },
          "allowFromFocusedApp": false
        },
        "transitions": [
          { "trigger": "activity", "match": { "categories": ["meeting"] }, "forSeconds": 60, "priority": 10 }
        ]
      },
      {
        "schemaVersion": 1,
        "id": "break",
        "name": "Break",
        "symbol": "cup.and.saucer",
        "description": "Away from the keyboard or deliberately resting. Everything is delivered; work apps step back.",
        "dock": {
          "prioritized": ["com.apple.Music", "com.spotify.client", "com.apple.Photos"]
        },
        "notifications": {
          "default": "allow"
        },
        "transitions": [
          { "trigger": "idle", "forSeconds": 600, "priority": 5 }
        ]
      },
      {
        "schemaVersion": 1,
        "id": "free",
        "name": "Free",
        "symbol": "sparkles",
        "description": "No particular focus. Nothing is filtered and nothing counts as a distraction.",
        "notifications": {
          "default": "allow",
          "rules": [
            { "match": { "categories": ["promotion"] }, "action": "summarize" }
          ]
        },
        "transitions": [
          { "trigger": "activity", "match": { "categories": ["browsing", "communication", "media", "other"] }, "forSeconds": 900, "from": ["break"] }
        ]
      }
    ]
    """#
}
