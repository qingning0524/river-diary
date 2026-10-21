import Foundation
import Testing
@testable import RiverDiaryCore

struct LegalLinksTests {
    @Test func legalLinksAreHTTPSOnThePublicSiteAndUseDistinctPaths() {
        let links = [
            RiverLegalLinks.privacyPolicy,
            RiverLegalLinks.terms,
            RiverLegalLinks.serviceStatus,
            RiverLegalLinks.securityContact,
        ]

        #expect(Set(links.map(\.absoluteString)).count == 4)
        for link in links {
            #expect(link.scheme == "https")
            #expect(link.host == "flowriver.xyz")
            #expect(link.path.hasPrefix("/") == true)
        }
        #expect(RiverLegalLinks.privacyPolicy.path == "/privacy.html")
        #expect(RiverLegalLinks.terms.path == "/terms.html")
        #expect(RiverLegalLinks.serviceStatus.path == "/status")
        #expect(RiverLegalLinks.securityContact.path == "/.well-known/security.txt")
    }
}
