import SwiftUI

enum WorkspacePagination {
  static let pageSize = 10
}

extension Array {
  func pageItems(page: Int, pageSize: Int = WorkspacePagination.pageSize) -> [Element] {
    guard !isEmpty, pageSize > 0 else { return [] }
    let pageCount = Swift.max(1, (count + pageSize - 1) / pageSize)
    let validPage = Swift.min(Swift.max(page, 1), pageCount)
    let start = (validPage - 1) * pageSize
    let end = Swift.min(start + pageSize, count)
    return Array(self[start..<end])
  }
}

struct PaginationBar: View {
  let totalCount: Int
  @Binding var currentPage: Int
  var pageSize = WorkspacePagination.pageSize
  var showsTopDivider = true

  private var pageCount: Int {
    max(1, Int(ceil(Double(totalCount) / Double(max(pageSize, 1)))))
  }

  private var validPage: Int {
    min(max(currentPage, 1), pageCount)
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsTopDivider {
        Divider()
      }

      HStack(spacing: 10) {
        Text("共 \(totalCount) 条")
          .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        Button {
          currentPage = max(1, validPage - 1)
        } label: {
          Image(systemName: "chevron.left")
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(validPage <= 1)
        .help("上一页")

        Text("第 \(validPage) / \(pageCount) 页")
          .frame(minWidth: 76)

        Button {
          currentPage = min(pageCount, validPage + 1)
        } label: {
          Image(systemName: "chevron.right")
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(validPage >= pageCount)
        .help("下一页")
      }
      .font(.caption.monospacedDigit())
      .padding(.horizontal, 14)
      .frame(height: 38)
    }
    .onAppear(perform: clampPage)
    .onChange(of: totalCount) { clampPage() }
    .onChange(of: pageSize) { clampPage() }
  }

  private func clampPage() {
    if currentPage != validPage {
      currentPage = validPage
    }
  }
}
