import Testing

@testable import DisplayDJCore

@Test("A list-printed runtime selector is parsed as a runtime ID")
func cliSelectorParsesRuntimeIDFromList() throws {
  #expect(try DisplayCLISelector.parse("runtime:2") == .runtimeID(2))
  #expect(try DisplayCLISelector.parse("  RUNTIME:10\n") == .runtimeID(10))
}

@Test("A stable ID from list stays a stable selector")
func cliSelectorParsesStableID() throws {
  #expect(
    try DisplayCLISelector.parse("uuid:c8e8de66-1e55-4b58-b12b-5980cbba2f64")
      == .stableID("uuid:c8e8de66-1e55-4b58-b12b-5980cbba2f64")
  )
}

@Test("Malformed runtime selectors fail before they can be treated as stable IDs")
func cliSelectorRejectsMalformedRuntimeIDs() {
  for value in ["runtime:", "runtime:-1", "runtime:2a", "runtime:999999999999"] {
    do {
      _ = try DisplayCLISelector.parse(value)
      Issue.record("Expected an invalid-selector error for \(value).")
    } catch let error as DisplayDJError {
      #expect(error.code == .invalidSelector)
      #expect(error.details["reason"] == "invalid-runtime-selector")
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }
}

@Test("Control characters and empty selectors remain invalid")
func cliSelectorRejectsEmptyAndControlCharacters() {
  do {
    _ = try DisplayCLISelector.parse("\n")
    Issue.record("Expected an invalid-selector error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .invalidSelector)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}
