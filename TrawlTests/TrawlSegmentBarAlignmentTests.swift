//
//  TrawlSegmentBarAlignmentTests.swift
//  TrawlTests
//
//  Every segment bar in the app follows one alignment rule instead of a per-call
//  option, which left Search's two bars aligned differently on the same screen.
//

import Testing
@testable import Trawl

@Suite("Segment bar alignment")
struct TrawlSegmentBarAlignmentTests {
    @Test("A plain pair of choices is centred")
    func pairCentres() {
        #expect(TrawlSegmentBar<Int>.centresItems(itemCount: 2, hasSearch: false))
    }

    /// Discover / Library centres; All / Series / Movies leads, because an "All"
    /// filter makes three.
    @Test("Three or more items lead")
    func longerBarsLead() {
        #expect(!TrawlSegmentBar<Int>.centresItems(itemCount: 3, hasSearch: false))
        #expect(!TrawlSegmentBar<Int>.centresItems(itemCount: 5, hasSearch: false))
    }

    /// The search field expands from the leading edge, so a bar carrying one leads
    /// whatever its length.
    @Test("A bar with search leads, even with two items")
    func searchLeads() {
        #expect(!TrawlSegmentBar<Int>.centresItems(itemCount: 2, hasSearch: true))
    }

    @Test("A single item leads")
    func singleLeads() {
        #expect(!TrawlSegmentBar<Int>.centresItems(itemCount: 1, hasSearch: false))
    }
}
