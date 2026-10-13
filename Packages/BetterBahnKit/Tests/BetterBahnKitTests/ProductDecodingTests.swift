import Foundation
import Testing
@testable import BetterBahnKit

/// Saved data written by a build with more product groups must stay readable by one with fewer.
/// The unknown values are made up on purpose: real groups like `nightTrain` become known once a build adds them.
struct ProductDecodingTests {
    @Test func anUnknownProductReadsAsOther() throws {
        let decoded = try JSONDecoder().decode(Set<Product>.self, from: Data(#"["highSpeed","hyperloop","zeppelin","regional"]"#.utf8))
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
        let json = #"{"products":["hyperloop","longDistance"],"line":"zeppelin"}"#
        let holder = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        #expect(holder.products == [.other, .longDistance])
        #expect(holder.line == .other)
    }
}
