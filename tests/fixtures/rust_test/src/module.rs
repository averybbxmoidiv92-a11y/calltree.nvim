// module.rs — exercises `crate::foo()` cross-module reference path.

pub fn module_func() -> u32 {
    crate::foo()
}
