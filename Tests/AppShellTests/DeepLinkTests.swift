@testable import AppShell
import ConnectionsFeature
import Foundation
import RedisCore
import Testing

struct DeepLinkTests {
    private func link(_ query: String) throws -> DatabaseDeepLink {
        let url = try #require(URL(string: "keystrand://databases/connect?\(query)"))
        return try #require(DatabaseDeepLink.parse(url))
    }

    @Test func mapsRedirectPages() {
        #expect(DeepLink.redirect("workbench") == .workbench(script: nil))
        #expect(DeepLink.redirect("/browser") == .section(.browser))
        #expect(DeepLink.redirect("analytics/slowlog") == .analytics(.slowLog))
        #expect(DeepLink.redirect("pub-sub") == .pubSub)
        #expect(DeepLink.redirect("workbench?tutorialId=ds-json-intro") == .tutorial(id: "ds-json-intro"))
        #expect(DeepLink.redirect("settings") == nil)
    }

    @MainActor
    @Test func redirectAttachesToTheLinkedDatabaseOnly() throws {
        let deepLink = try link("redisUrl=redis%3A%2F%2Fu%3Ap%40redis.example.com%3A6380&redirect=analytics%2Fslowlog")
        DeepLinkRedirects.expect(deepLink)

        let other = DatabaseConfig(name: "Other", host: "other.example.com", port: 6380)
        DeepLinkRedirects.databaseOpened(other)
        #expect(DeepLinkRedirects.consume(other.id) == nil)

        let linked = DatabaseConfig(name: "Any alias", host: "redis.example.com", port: 6380, username: "u")
        DeepLinkRedirects.databaseOpened(linked)
        #expect(DeepLinkRedirects.consume(linked.id) == .analytics(.slowLog))
        #expect(DeepLinkRedirects.consume(linked.id) == nil)

        DeepLinkRedirects.databaseOpened(linked)
        #expect(DeepLinkRedirects.consume(linked.id) == nil)
    }

    @MainActor
    @Test func cancelledLinkDropsItsRedirect() throws {
        let deepLink = try link("redisUrl=redis%3A%2F%2Fu%3Ap%40redis.example.com%3A6382&redirect=workbench")
        DeepLinkRedirects.expect(deepLink)
        DeepLinkRedirects.cancel(try link("redisUrl=redis%3A%2F%2Fu%3Ap%40other.example.com%3A6382"))
        DeepLinkRedirects.cancel(deepLink)
        let linked = DatabaseConfig(name: "x", host: "redis.example.com", port: 6382, username: "u")
        DeepLinkRedirects.databaseOpened(linked)
        #expect(DeepLinkRedirects.consume(linked.id) == nil)
    }

    @MainActor
    @Test func linksWithoutRedirectQueueNothing() throws {
        DeepLinkRedirects.expect(try link("redisUrl=redis%3A%2F%2Fu%3Ap%40redis.example.com%3A6381"))
        let linked = DatabaseConfig(name: "x", host: "redis.example.com", port: 6381, username: "u")
        DeepLinkRedirects.databaseOpened(linked)
        #expect(DeepLinkRedirects.consume(linked.id) == nil)
    }
}
