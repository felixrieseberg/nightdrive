import Darwin
import Testing

@testable import Nightdrive

struct FileGenerationStampTests {
  @Test
  func negativeDeviceIDUsesItsBitPattern() {
    var status = stat()
    status.st_dev = -1

    let stamp = FileGenerationStamp(status)

    #expect(stamp.deviceID == UInt64(bitPattern: Int64(status.st_dev)))
  }
}
