@testable import cartograph
import Foundation
import Testing

@Suite("변경 줄 좌표")
struct ChangedLinesTests {
    @Test("추가·수정·삭제 hunk 를 현재 줄로 읽고 순수 삭제는 빈 범위다")
    func currentHunks() {
        #expect(ChangedLines.ranges(in: Data("@@ -2,2 +4,3 @@ f\n-old\n+new\n@@ -9 +12 @@\n-a\n+b\n".utf8))
            == [4...6, 12...12])
        #expect(ChangedLines.ranges(in: Data("@@ -2,2 +1,0 @@\n-a\n-b\n".utf8)) == [])
        #expect(ChangedLines.ranges(in: Data("@@ -0,0 +1,2 @@\n+a\n+b\n".utf8)) == [1...2])
    }

    @Test("이진·모드·불명확하거나 넘친 좌표는 파일 전체로 대체한다")
    func uncertainPatches() {
        for patch in ["", "old mode 100644\nnew mode 100755\n", "Binary files a and b differ\n",
                      "@@@ -1 -1 +1 @@@\n", "@@ -1 +0 @@\n", "@@ -x +2 @@\n",
                      "@@ -1 +2,-1 @@\n", "@@ -1 +\(Int.max),2 @@\n",
                      "index abc..def 120000\n@@ -1 +1 @@\n-a\n+b\n"] {
            #expect(ChangedLines.ranges(in: Data(patch.utf8)) == nil)
        }
        #expect(ChangedLines.ranges(in: Data([0xff])) == nil)
    }
}
