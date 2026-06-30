import Testing
@testable import SeedkeepCloudKit

@Test("DUMP: emit the deployable CKDSL schema")
func dumpSchema() {
    print("=====CKDSL_BEGIN=====")
    print(SeedkeepRecordType.allCKDSL())
    print("=====CKDSL_END=====")
}
