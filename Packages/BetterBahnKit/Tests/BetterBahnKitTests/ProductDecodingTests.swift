import Foundation
import Testing
@testable import BetterBahnKit

/// Saved data written by a build with more product groups must stay readable by one with fewer. The values
/// below are made up on purpose: real new groups (nightTrain, interregio) become known cases once a build has them.
struct ProductDecodingTests {
    @Test func anUnknownProductReadsAsOther() throws {
        let decoded = try JSONDecoder().decode(Set<Product>.self, from: Data(#"["highSpeed","hyperloop","teleporter","regional"]"#.utf8))
        #expect(decoded == [.highSpeed, .regional, .other])
    }

    @Test func knownProductsAreUnchanged() throws {
        let all = Set(Product.allCases)
        let data = try JSONEncoder().encode(all)
        #expect(try JSONDecoder().decode(Set<Product>.self, from: data) == all)
        #expect(String(decoding: try JSONEncoder().encode(Product.longDistance), as: UTF8.self) == "\"longDistance\"")
    }

    /// One unknown value inside a struct must not make the whole struct fail.
    @Test func anUnknownProductInsideAStructStillDecodes() throws {
        struct Holder: Codable { var products: Set<Product>; var line: Product }
        let json = #"{"products":["hyperloop","longDistance"],"line":"teleporter"}"#
        let holder = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        #expect(holder.products == [.other, .longDistance])
        #expect(holder.line == .other)
    }
}
