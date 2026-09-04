import Foundation
import SQLite3

public enum NotificationDatabaseLocation {
  public static func candidates(
    homeDirectory: String,
    darwinUserDirectory: String?
  ) -> [URL] {
    var values = [
      URL(fileURLWithPath: homeDirectory, isDirectory: true)
        .appendingPathComponent(
          "Library/Group Containers/group.com.apple.usernoted/db2/db"
        )
    ]
    if let darwinUserDirectory = darwinUserDirectory,
      !darwinUserDirectory.isEmpty
    {
      values.append(
        URL(fileURLWithPath: darwinUserDirectory, isDirectory: true)
          .appendingPathComponent("com.apple.notificationcenter/db2/db")
      )
    }
    return values
  }

  public static func resolve(
    homeDirectory: String,
    darwinUserDirectory: String?,
    fileExists: (String) -> Bool,
    isReadable: (String) -> Bool
  ) -> URL {
    let values = candidates(
      homeDirectory: homeDirectory,
      darwinUserDirectory: darwinUserDirectory
    )
    return values.first(where: {
      fileExists($0.path) && isReadable($0.path)
    }) ?? values[0]
  }

  public static func defaultURL() -> URL {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
    let darwinDirectory = environment["DARWIN_USER_DIR"] ?? systemDarwinUserDirectory()
    let values = candidates(
      homeDirectory: homeDirectory,
      darwinUserDirectory: darwinDirectory
    )
    if let existing = values.first(where: {
      isUsableNotificationDatabase(atPath: $0.path)
    }) {
      return existing
    }
    if #available(macOS 14, *) {
      return values[0]
    }
    return values.count > 1 ? values[1] : values[0]
  }

  private static func isUsableNotificationDatabase(atPath path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path),
      FileManager.default.isReadableFile(atPath: path)
    else {
      return false
    }

    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let openedDatabase = database
    else {
      if let openedDatabase = database { sqlite3_close(openedDatabase) }
      return false
    }
    defer { sqlite3_close(openedDatabase) }

    var statement: OpaquePointer?
    let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='record' LIMIT 1"
    guard sqlite3_prepare_v2(openedDatabase, sql, -1, &statement, nil) == SQLITE_OK,
      let preparedStatement = statement
    else {
      return false
    }
    defer { sqlite3_finalize(preparedStatement) }
    return sqlite3_step(preparedStatement) == SQLITE_ROW
  }

  private static func systemDarwinUserDirectory() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
    process.arguments = ["DARWIN_USER_DIR"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let value = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}
