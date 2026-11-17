import Foundation
import ImageIO
import SwiftUI

// MARK: - Modelo

struct Article: Codable, Identifiable {
    struct Author: Codable {
        let name: String
    }

    let id: Int
    let title: String
    let description: String
    let coverImage: URL?
    let user: Author
    let url: URL
    let bodyMarkdown: String?

    var readableMarkdown: String? {
        guard let bodyMarkdown,
              !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return bodyMarkdown
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, user, url
        case coverImage = "cover_image"
        case bodyMarkdown = "body_markdown"
    }
}

private enum LoadState<Value> {
    case idle, loading, success(Value), failure(String)
}

private enum ArticleError: LocalizedError {
    case invalidEndpoint, invalidResponse, httpStatus(Int), missingBody

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "O endereço da API do DEV é inválido."
        case .invalidResponse: return "O servidor enviou uma resposta inválida."
        case .httpStatus(let status): return "O servidor respondeu com o código HTTP \(status)."
        case .missingBody: return "O texto deste artigo está indisponível."
        }
    }
}

// MARK: - Rede e persistência

private enum DevAPI {
    static func feed() async throws -> [Article] {
        try await get([Article].self, articleID: nil)
    }

    static func completeArticle(id: Int) async throws -> Article {
        try await get(Article.self, articleID: id)
    }

    private static func get<Value: Decodable>(_ type: Value.Type, articleID: Int?) async throws -> Value {
        guard let baseURL = URL(string: "https://dev.to/api/articles") else { throw ArticleError.invalidEndpoint }
        let url = articleID.map { baseURL.appendingPathComponent(String($0)) } ?? baseURL
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.forem.api-v1+json", forHTTPHeaderField: "Accept")
        let data = try await HTTPClient.data(for: request)
        return try JSONDecoder().decode(type, from: data)
    }
}

private enum HTTPClient {
    static func data(for request: URLRequest) async throws -> Data {
        // O await suspende a tarefa durante a requisição sem bloquear a interface.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ArticleError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ArticleError.httpStatus(response.statusCode) }
        return data
    }

    static func cover(at url: URL) async throws -> CGImage? {
        let data = try await data(for: URLRequest(url: url, timeoutInterval: 20))
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 1200
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct FavoritesStore {
    private let defaults: UserDefaults
    private let key = "TechNews.savedArticles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [Article] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([Article].self, from: data)
    }

    func save(_ articles: [Article]) throws {
        defaults.set(try JSONEncoder().encode(articles), forKey: key)
    }
}

// MARK: - ViewModels

// As views enviam ações e observam estado. A ViewModel coordena a API e o armazenamento.
@MainActor
private final class NewsViewModel: ObservableObject {
    @Published private(set) var feed: LoadState<[Article]> = .idle
    @Published private(set) var favorites: [Article] = []
    @Published private(set) var downloading: Set<Int> = []
    @Published var message: String?

    private let store = FavoritesStore()
    private var isLoading = false

    init() {
        do {
            favorites = try store.load()
        } catch {
            message = "Não foi possível carregar os artigos salvos."
        }
    }

    func loadFeedIfNeeded() {
        guard case .idle = feed else { return }
        // O feed é compartilhado. Fechar uma janela não deve interromper a carga das demais.
        Task { await loadFeed() }
    }

    func loadFeed() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let previous = feed
        switch previous {
        case .success: break
        default: feed = .loading
        }

        do {
            let articles = try await DevAPI.feed()
            try Task.checkCancellation()
            feed = .success(articles)
        } catch {
            if Task.isCancelled {
                feed = previous
            } else if case .success = previous {
                message = "Não foi possível atualizar o feed. \(error.localizedDescription)"
            } else {
                feed = .failure(error.localizedDescription)
            }
        }
    }

    func savedArticle(id: Int) -> Article? {
        favorites.first { $0.id == id }
    }

    func articleForReading(_ article: Article) -> Article {
        savedArticle(id: article.id) ?? article
    }

    func toggleFavorite(_ article: Article) async {
        guard !downloading.contains(article.id) else { return }
        do {
            if savedArticle(id: article.id) != nil {
                try persist(favorites.filter { $0.id != article.id })
                return
            }

            downloading.insert(article.id)
            defer { downloading.remove(article.id) }

            // A listagem traz só o resumo. Buscamos o texto antes de confirmar o favorito.
            let complete: Article
            if article.readableMarkdown != nil {
                complete = article
            } else {
                complete = try await DevAPI.completeArticle(id: article.id)
            }
            try Task.checkCancellation()
            guard complete.readableMarkdown != nil else { throw ArticleError.missingBody }
            // Usamos a lista atual após o await para preservar outros favoritos salvos em paralelo.
            try persist([complete] + favorites)
        } catch {
            guard !Task.isCancelled else { return }
            message = "Não foi possível atualizar os salvos. \(error.localizedDescription)"
        }
    }

    private func persist(_ articles: [Article]) throws {
        try store.save(articles)
        favorites = articles
    }
}

@MainActor
private final class ReaderViewModel: ObservableObject {
    @Published private(set) var content: LoadState<AttributedString>
    private let article: Article

    init(article: Article) {
        self.article = article
        if let markdown = article.readableMarkdown {
            content = .success(Self.format(markdown))
        } else {
            content = .idle
        }
    }

    func load() async {
        switch content {
        case .loading, .success: return
        case .idle, .failure: break
        }
        content = .loading
        do {
            let complete = try await DevAPI.completeArticle(id: article.id)
            try Task.checkCancellation()
            guard let markdown = complete.readableMarkdown else { throw ArticleError.missingBody }
            content = .success(Self.format(markdown))
        } catch {
            content = Task.isCancelled ? .idle : .failure(error.localizedDescription)
        }
    }

    private static func format(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

@MainActor
private final class CoverViewModel: ObservableObject {
    @Published private(set) var image: LoadState<CGImage> = .idle

    func load(_ url: URL) async {
        image = .loading
        do {
            let cover = try await HTTPClient.cover(at: url)
            // A lista cancela a tarefa quando a capa sai de cena ou muda de URL.
            try Task.checkCancellation()
            image = cover.map { .success($0) } ?? .failure("Imagem indisponível.")
        } catch {
            guard !Task.isCancelled else { return }
            image = .failure("Imagem indisponível.")
        }
    }
}

// MARK: - Views

@main
@MainActor
struct TechNewsApp: App {
    // As janelas compartilham a lista de salvos e as operações em andamento.
    @StateObject private var model = NewsViewModel()

    var body: some Scene {
        WindowGroup { NewsView(model: model) }
    }
}

@MainActor
private struct NewsView: View {
    @ObservedObject private var model: NewsViewModel
    @State private var selectedArticle: Article?

    init(model: NewsViewModel) {
        self.model = model
    }

    var body: some View {
        TabView {
            NavigationStack {
                feedContent.navigationTitle("TechNews")
            }
            .tabItem { Label("Feed", systemImage: "newspaper") }

            NavigationStack {
                Group {
                    if model.favorites.isEmpty {
                        status("Nenhum artigo salvo", icon: "bookmark", detail: "Favorite um artigo no feed para ler o texto offline.")
                    } else {
                        articleList(model.favorites, showsCover: false)
                    }
                }
                .navigationTitle("Salvos")
            }
            .tabItem { Label("Salvos", systemImage: "bookmark") }
        }
        .tint(Color(red: 0.37, green: 0.34, blue: 0.80))
        .onAppear { model.loadFeedIfNeeded() }
        .sheet(item: $selectedArticle) { article in
            NavigationStack {
                ReaderView(article: article)
            }
        }
        .alert("TechNews", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    @ViewBuilder private var feedContent: some View {
        switch model.feed {
        case .idle, .loading:
            ProgressView("Carregando artigos…")
        case .success(let articles) where articles.isEmpty:
            status("Feed vazio", icon: "newspaper", detail: "O DEV não retornou artigos.", canRetry: true)
        case .success(let articles):
            articleList(articles, showsCover: true)
                .refreshable { await model.loadFeed() }
        case .failure(let message):
            status("Feed indisponível", icon: "wifi.exclamationmark", detail: message, canRetry: true)
        }
    }

    private func articleList(_ articles: [Article], showsCover: Bool) -> some View {
        List(articles) { article in
            let saved = model.savedArticle(id: article.id) != nil
            let downloading = model.downloading.contains(article.id)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    selectedArticle = model.articleForReading(article)
                } label: {
                    ArticleSummary(article: article, showsCover: showsCover)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await model.toggleFavorite(article) }
                } label: {
                    if downloading {
                        HStack {
                            ProgressView()
                            Text("Salvando…")
                        }
                    } else {
                        Label(saved ? "Remover dos salvos" : "Favoritar", systemImage: saved ? "bookmark.fill" : "bookmark")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(downloading)
            }
            .padding(.vertical, 10)
        }
        .listStyle(.plain)
    }

    private func status(_ title: String, icon: String, detail: String, canRetry: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
            if canRetry {
                Button("Tentar novamente") { Task { await model.loadFeed() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }
}

@MainActor
private struct ArticleSummary: View {
    let article: Article
    let showsCover: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCover, let cover = article.coverImage {
                ArticleCover(url: cover)
            }
            Text(article.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(article.user.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if !article.description.isEmpty {
                Text(article.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct ArticleCover: View {
    let url: URL
    @StateObject private var model = CoverViewModel()

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .aspectRatio(2.4, contentMode: .fit)
            .overlay {
                switch model.image {
                case .success(let image): Image(decorative: image, scale: 1).resizable().scaledToFill()
                case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                default: ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            .task(id: url) { await model.load(url) }
    }
}

@MainActor
private struct ReaderView: View {
    let article: Article
    @StateObject private var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    init(article: Article) {
        self.article = article
        _model = StateObject(wrappedValue: ReaderViewModel(article: article))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(article.title).font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(article.user.name).foregroundStyle(.secondary)

                switch model.content {
                case .idle, .loading:
                    ProgressView("Carregando texto…")
                case .success(let markdown):
                    Text(markdown)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                case .failure(let message):
                    Text(message).foregroundStyle(.secondary)
                    Button("Tentar novamente") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }

                Link("Abrir no DEV", destination: article.url)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Leitura")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fechar") { dismiss() }
            }
        }
        .task { await model.load() }
    }
}
