import Testing
import GRDB

@Test func grdbOpens() throws {
    let q = try DatabaseQueue()
    try q.write { try $0.execute(sql: "CREATE TABLE t(x)") }
}

@Test func int128Available() {
    let x: Int128 = 170_141_183_460_469_231_731_687_303_715_884_105_727
    #expect(x > 0)
}
