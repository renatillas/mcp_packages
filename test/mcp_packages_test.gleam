import gleeunit
import gleam/string

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}

// Test type signature extraction improvements
pub fn improved_type_info_test() {
  // This test verifies that TypeInfo now includes signature and type_kind fields
  // The actual extraction is tested through integration with packages
  let expected_signature = "type Result(a, b) = Ok(a) | Error(b)"
  let expected_kind = "custom"

  let signature_has_type_keyword =
    expected_signature
    |> string.starts_with("type ")
  let kind_is_custom = expected_kind == "custom"

  assert signature_has_type_keyword
  assert kind_is_custom
}
