use rust_test::{foo, MyStruct, Trait};

fn main() {
    // Cross-file caller of `foo` (defined in lib.rs).
    let _ = foo();

    // Cross-file caller of `MyStruct::method`.
    let s = MyStruct;
    let _ = s.method();

    // Cross-file caller of `trait_method` (optional; some test cases
    // expect this to be unused — that's fine).
    s.trait_method();
}
