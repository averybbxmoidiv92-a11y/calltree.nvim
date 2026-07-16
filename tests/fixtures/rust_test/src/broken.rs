// broken.rs — intentionally contains a syntax error for calltree.nvim
// test case 10 (syntax error recovery). This file is intentionally NOT
// declared as a module in lib.rs so it doesn't break the rest of the
// crate; rust-analyzer still parses it standalone when opened in nvim.

pub fn broken() -> u32 {
    1 +
}
