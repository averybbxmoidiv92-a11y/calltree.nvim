pub fn foo() -> u32 {
    0
}
pub fn bar() -> u32 {
    foo()
}
pub fn uses_helper() -> u32 {
    helper()
}
pub struct MyStruct;
impl MyStruct {
 pub fn method(&self) -> u32 {
  0
 }
}
pub trait Trait { fn trait_method(&self); }
impl Trait for MyStruct {
 fn trait_method(&self) {
 }
}
pub fn uses_std() -> String {
    std::fs::read_to_string("foo").unwrap_or_default()
}
pub fn uses_serde() -> String {
    serde_json::to_string(&42).unwrap_or_default()
}
#[cfg(target_os = "linux")]
pub fn conditional_func() -> u32 { 1 }
#[cfg(not(target_os = "linux"))]
pub fn conditional_func() -> u32 { 2 }
pub fn closure_target() -> u32 { 0 }
pub fn closure_caller() -> u32 {
    let f = || closure_target();
    f()
}
fn helper() -> u32 { 0 }
mod module;
