import Foundation
import GRDB

struct GraphNode: Identifiable, Hashable {
    let id: String
    let title: String
    let app: String
    let kind: String
    let thumb: String?
    let file: String?
    let url: String?
    let createdAt: String
    var tags: [String] = []
    var summary: String = ""
    var bundleID: String = ""
}

struct GraphEdge: Hashable {
    let a: String
    let b: String
    let weight: Double
}

/// Builds the memory graph: every document (deliberate + passive) is a node;
/// edges come from the engine's own semantic search. Per-doc neighbor lists
/// are cached in SQLite keyed by (docID, updatedAt) so only new or changed
/// documents cost a search.
actor GraphService {
    static let shared = GraphService()

    enum Scope: String, CaseIterable, Sendable {
        case saved = "Saved"
        case screen = "Screen"
        case all = "All"

        var tags: [String] {
            switch self {
            case .saved: return [Settings.savedTag]
            case .screen: return ["recall"]
            case .all: return [Settings.savedTag, "recall", "constellation"]
            }
        }
    }

    private var tags = Scope.saved.tags

    private func client(_ settings: SettingsSnapshot) -> SupermemoryClient {
        SupermemoryClient(baseURL: settings.supermemoryURL, apiKey: settings.supermemoryKey)
    }

    struct SettingsSnapshot: Sendable {
        var supermemoryURL: URL
        var supermemoryKey: String
    }

    func build(_ settings: SettingsSnapshot, scope: Scope = .saved) async -> (nodes: [GraphNode], edges: [GraphEdge]) {
        tags = scope.tags
        let docs = await listAllDocuments(settings)
        var byRef: [String: String] = [:]
        for d in docs {
            if let ref = d.metadata["ref"] as? String { byRef[ref] = d.id }
        }

        var edges: Set<GraphEdge> = []
        for doc in docs {
            let cacheKey = "\(doc.id):\(doc.updatedAt)"
            var neighbors = await Store.shared.cachedNeighbors(key: cacheKey)
            if neighbors == nil {
                neighbors = await findNeighbors(doc: doc, byRef: byRef, settings: settings)
                if let n = neighbors {
                    await Store.shared.cacheNeighbors(key: cacheKey, neighbors: n)
                }
            }
            for n in neighbors ?? [] where n.id != doc.id {
                let (a, b) = doc.id < n.id ? (doc.id, n.id) : (n.id, doc.id)
                edges.insert(GraphEdge(a: a, b: b, weight: n.score))
            }
        }

        let nodes = docs.map { d in
            GraphNode(
                id: d.id,
                title: d.title,
                app: (d.metadata["app_name"] as? String) ?? (d.metadata["app"] as? String) ?? "note",
                kind: (d.metadata["source"] as? String) == "screen-capture" ? "recall" : "capture",
                thumb: d.metadata["thumb"] as? String,
                file: d.metadata["file"] as? String,
                url: d.metadata["url"] as? String,
                createdAt: (d.metadata["captured_at"] as? String) ?? d.createdAt,
                tags: ((d.metadata["tags"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                summary: d.summary,
                bundleID: (d.metadata["app"] as? String) ?? ""
            )
        }
        return (nodes, Array(edges))
    }

    // MARK: internals

    struct Doc {
        let id: String
        let title: String
        let summary: String
        let updatedAt: String
        let createdAt: String
        let metadata: [String: Any]
    }

    private func listAllDocuments(_ settings: SettingsSnapshot) async -> [Doc] {
        var docs: [Doc] = []
        var page = 1
        while true {
            guard let data = try? await postJSON(
                settings, path: "v3/documents/list",
                body: ["containerTags": tags, "limit": 100, "page": page, "sort": "createdAt", "order": "desc"]
            ), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for m in (obj["memories"] as? [[String: Any]]) ?? [] {
                guard let id = m["id"] as? String, (m["status"] as? String) != "failed" else { continue }
                docs.append(Doc(
                    id: id,
                    title: (m["title"] as? String) ?? "Untitled",
                    summary: (m["summary"] as? String) ?? "",
                    updatedAt: (m["updatedAt"] as? String) ?? "",
                    createdAt: (m["createdAt"] as? String) ?? "",
                    metadata: (m["metadata"] as? [String: Any]) ?? [:]
                ))
            }
            let pagination = obj["pagination"] as? [String: Any]
            let current = (pagination?["currentPage"] as? Int) ?? page
            let total = (pagination?["totalPages"] as? Int) ?? 1
            if current >= total { break }
            page = current + 1
        }
        return docs
    }

    struct Neighbor: Codable {
        let id: String
        let score: Double
    }

    private func findNeighbors(doc: Doc, byRef: [String: String], settings: SettingsSnapshot) async -> [Neighbor] {
        let query = [doc.title, doc.summary].filter { !$0.isEmpty }.joined(separator: " — ")
        guard !query.isEmpty else { return [] }
        var found: [Neighbor] = []
        var seen = Set<String>()
        for tag in tags {
            guard let data = try? await postJSON(
                settings, path: "v4/search",
                body: ["q": String(query.prefix(350)), "containerTag": tag, "limit": 6, "threshold": 0.4]
            ), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for r in (obj["results"] as? [[String: Any]]) ?? [] {
                guard let meta = r["metadata"] as? [String: Any],
                      let ref = meta["ref"] as? String,
                      let docID = byRef[ref],
                      docID != doc.id,
                      !seen.contains(docID) else { continue }
                seen.insert(docID)
                found.append(Neighbor(id: docID, score: (r["similarity"] as? Double) ?? 0.5))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(4))
    }

    private func postJSON(_ settings: SettingsSnapshot, path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: settings.supermemoryURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.supermemoryKey.isEmpty {
            req.setValue("Bearer \(settings.supermemoryKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
