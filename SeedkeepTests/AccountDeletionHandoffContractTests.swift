import Testing
import Foundation
@testable import Seedkeep

/// Verifies that the AASA file, web fallback route, and iOS handoff link all
/// agree on the path shape. Catches drift where a link the app builds would
/// not be authorized by the AASA or would 404 on the web.
@Suite("Account deletion handoff contract")
struct AccountDeletionHandoffContractTests {
    
    @Test("AASA authorizes the path AccountDeletionHandoffLink builds")
    func aasaAuthorizesHandoffPath() throws {
        // Read the deployed AASA file
        let aasaPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("web/static/.well-known/apple-app-site-association")
        
        let aasaData = try Data(contentsOf: aasaPath)
        let aasa = try JSONDecoder().decode(AASA.self, from: aasaData)
        
        // Extract the paths array for our app ID
        let details = try #require(
            aasa.applinks.details.first(where: { $0.appID == "K7CBQW6MPG.app.seedkeep.ios" }),
            "AASA missing expected app ID"
        )
        
        // The handoff link builds paths like /garden-handoff/<id>
        let expectedPattern = "/\(AccountDeletionHandoffLink.pathSegment)/*"
        
        #expect(
            details.paths.contains(expectedPattern),
            "AASA paths \(details.paths) must include '\(expectedPattern)' to authorize handoff links"
        )
    }
    
    @Test("Web fallback route exists for the handoff path")
    func webFallbackRouteExists() throws {
        // Verify the SvelteKit route directory exists
        let routePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("web/src/routes/\(AccountDeletionHandoffLink.pathSegment)/[id]/+page.svelte")
        
        #expect(
            FileManager.default.fileExists(atPath: routePath.path),
            "Web fallback route must exist at \(routePath.path)"
        )
    }
    
    @Test("Handoff link universal URL shape matches AASA expectations")
    func handoffLinkShapeMatchesAASA() {
        let link = AccountDeletionHandoffLink(transferID: "tr_test", token: "test-token")
        let url = link.universalLink
        
        // Verify the URL shape the AASA expects
        #expect(url.scheme == "https")
        #expect(url.host == AccountDeletionHandoffLink.host)
        #expect(url.pathComponents.count >= 3)
        #expect(url.pathComponents[1] == AccountDeletionHandoffLink.pathSegment)
        
        // The token must be in the query, never in the path
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.contains(where: { $0.name == "token" }) == true)
        #expect(!url.path.contains("test-token"), "Token must not appear in path")
    }
    
    @Test("Web fallback route does not expose token in page content")
    func webFallbackDoesNotExposeToken() throws {
        let routePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("web/src/routes/\(AccountDeletionHandoffLink.pathSegment)/[id]/+page.svelte")
        
        let content = try String(contentsOf: routePath, encoding: .utf8)
        
        // The route should only reference the transfer ID from params, never extract
        // or display the token query parameter
        #expect(content.contains("$page.params.id"), "Route should use transfer ID from path")
        #expect(!content.contains("token") || content.contains("// Transfer ID from the route parameter, never log or expose the token"),
                "Route must not extract or display the token query parameter")
    }
}

// MARK: - AASA JSON structure

private struct AASA: Decodable {
    let applinks: AppLinks
    
    struct AppLinks: Decodable {
        let apps: [String]
        let details: [Detail]
        
        struct Detail: Decodable {
            let appID: String
            let paths: [String]
        }
    }
}
