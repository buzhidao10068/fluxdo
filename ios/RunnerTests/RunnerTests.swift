import Darwin
import Foundation
import SafariServices
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testShortWritesPreserveEveryByte() {
    let body = Data("描述文件内容".utf8)
    var received = Data()
    XCTAssertTrue(MobileconfigTransfer.writeAll(body) { pointer, count in
      let length = min(3, count)
      received.append(pointer.assumingMemoryBound(to: UInt8.self), count: length)
      return length
    })
    XCTAssertEqual(received, body)
  }

  func testZeroWriteAndDisconnectFail() {
    for result in [0, -1] {
      var writes = 0
      XCTAssertFalse(MobileconfigTransfer.writeAll(Data([1, 2, 3])) { _, _ in
        writes += 1
        return writes == 1 ? 1 : result
      })
      XCTAssertEqual(writes, 2)
    }
  }

  func testCompletionRunsOnceOnMainQueue() {
    let completed = expectation(description: "唯一回调")
    completed.assertForOverFulfill = true
    let transfer = MobileconfigTransfer { success in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertTrue(success)
      completed.fulfill()
    }
    transfer.finish(true)
    transfer.finish(false)
    transfer.finish(true)
    wait(for: [completed], timeout: 2)
  }

  func testNoRequestTimesOutInsteadOfReportingSuccess() {
    let opened = expectation(description: "开始监听")
    let completed = expectation(description: "下载超时")
    let transfer = MobileconfigTransfer(timeout: 0.2) { success in
      XCTAssertFalse(success)
      completed.fulfill()
    }
    transfer.startServing("profile") { _ in opened.fulfill() }
    wait(for: [opened, completed], timeout: 3)
  }

  func testCancelReportsFailureOnce() {
    let completed = expectation(description: "取消")
    completed.assertForOverFulfill = true
    let transfer = MobileconfigTransfer { success in
      XCTAssertFalse(success)
      completed.fulfill()
    }
    transfer.safariViewControllerDidFinish(
      SFSafariViewController(url: URL(string: "http://127.0.0.1/")!))
    transfer.finish(true)
    wait(for: [completed], timeout: 2)
  }

  func testRealSocketSendsCompleteProfileAfterFragmentedRequest() {
    let completed = expectation(description: "完整发送后成功")
    let received = expectation(description: "读取响应")
    let profile = "<?xml version=\"1.0\"?><plist>测试描述文件</plist>"
    let body = Data(profile.utf8)
    let transfer = MobileconfigTransfer(timeout: 5) { success in
      XCTAssertTrue(success)
      completed.fulfill()
    }
    transfer.startServing(profile) { url in
      // 不能在 open 回调内阻塞 server 的 accept。
      DispatchQueue.global().async {
        defer { received.fulfill() }
        guard let client = self.connect(url) else { return }
        defer { close(client) }
        XCTAssertTrue(self.write(Data("GET \(url.path) HTTP/1.1\r\n".utf8), to: client))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(self.write(Data("Host: 127.0.0.1\r\n\r\n".utf8), to: client))
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = recv(client, &buffer, buffer.count, 0)
          if count == 0 { break }
          guard count > 0 else { XCTFail("读取响应失败"); return }
          response.append(contentsOf: buffer.prefix(count))
        }
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
          XCTFail("缺少 HTTP 响应头"); return
        }
        let header = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(header.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertEqual(Data(response[separator.upperBound...]), body)
      }
    }
    wait(for: [completed, received], timeout: 7)
  }

  func testClientDisconnectReportsFailure() {
    let completed = expectation(description: "断连失败")
    let transfer = MobileconfigTransfer(timeout: 2) { success in
      XCTAssertFalse(success)
      completed.fulfill()
    }
    transfer.startServing("profile") { url in
      if let client = self.connect(url) { close(client) }
    }
    wait(for: [completed], timeout: 4)
  }

  private func connect(_ url: URL) -> Int32? {
    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0 else { XCTFail("创建客户端失败"); return nil }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
               socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
               socklen_t(MemoryLayout<timeval>.size))
    var noSigpipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
               socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(url.port!).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { close(client); XCTFail("连接本地服务失败"); return nil }
    return client
  }

  private func write(_ data: Data, to socket: Int32) -> Bool {
    MobileconfigTransfer.writeAll(data) { pointer, count in
      send(socket, pointer, count, 0)
    }
  }
}
