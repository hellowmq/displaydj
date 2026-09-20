import Foundation

/// A display control value stored internally on a normalized 0...1 scale.
///
/// The public and encoded representation is always a percentage in 0...100.
public struct DisplayControlValue: Hashable, Sendable {
  private let storage: Double

  public init(percent: Double) throws {
    guard percent.isFinite, (0...100).contains(percent) else {
      throw DisplayDJError.invalidControlValue(percent, expectedRange: "0...100")
    }

    storage = percent == 0 ? 0 : percent / 100
  }

  public init(normalized: Double) throws {
    guard normalized.isFinite, (0...1).contains(normalized) else {
      throw DisplayDJError.invalidControlValue(normalized, expectedRange: "0...1")
    }

    storage = normalized == 0 ? 0 : normalized
  }

  public var percent: Double {
    storage * 100
  }

  public var normalized: Double {
    storage
  }
}

extension DisplayControlValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let percent = try container.decode(Double.self)

    do {
      try self.init(percent: percent)
    } catch let error as DisplayDJError {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: error.message
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(percent)
  }
}
