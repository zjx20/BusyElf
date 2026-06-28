import XCTest
@testable import BusyElf

/// 白盒:中立协议 body 的宽容解析。
final class TaskEventTests: XCTestCase {

    private func parse(_ json: String) -> TaskEvent? {
        TaskEvent.parse(Data(json.utf8))
    }

    func testParsesAllFields() {
        let e = parse(#"""
        {"id":"x","name":"Explore","agent":"a","cwd":"/c","prompt":"p",
         "tool":"Bash","toolInput":"ls","detail":"d","reply":"r","replyAppend":true,
         "message":"m","errorKind":"rate_limit","errorDetail":"ed","parentId":"par","totalTokens":1234}
        """#)
        XCTAssertEqual(e?.id, "x")
        XCTAssertEqual(e?.name, "Explore")
        XCTAssertEqual(e?.prompt, "p")
        XCTAssertEqual(e?.tool, "Bash")
        XCTAssertEqual(e?.toolInput, "ls")
        XCTAssertEqual(e?.reply, "r")
        XCTAssertEqual(e?.replyAppend, true)
        XCTAssertEqual(e?.errorKind, "rate_limit")
        XCTAssertEqual(e?.errorDetail, "ed")
        XCTAssertEqual(e?.parentId, "par")
        XCTAssertEqual(e?.totalTokens, 1234)
    }

    func testMissingOptionalFieldsAreNil() {
        let e = parse(#"{"id":"x"}"#)
        XCTAssertEqual(e?.id, "x")
        XCTAssertNil(e?.prompt)
        XCTAssertNil(e?.replyAppend)
        XCTAssertNil(e?.totalTokens)
    }

    func testNumberCoercedToString() {
        let e = parse(#"{"id":42}"#)
        XCTAssertEqual(e?.id, "42")          // 数字也强转字符串
    }

    func testBoolParse() {
        XCTAssertEqual(parse(#"{"id":"x","replyAppend":false}"#)?.replyAppend, false)
        XCTAssertEqual(parse(#"{"id":"x","replyAppend":true}"#)?.replyAppend, true)
    }

    func testNonJSONReturnsNil() {
        XCTAssertNil(parse("garbage"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("[1,2,3]"))       // 非对象
    }
}
