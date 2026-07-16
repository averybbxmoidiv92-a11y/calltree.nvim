LUABIN ?= lua5.4
NVIMBIN ?= nvim

.PHONY: test test-unit test-headless test-lsp test-c test-rust test-javascript test-all install clean

# Default: pure-Lua unit tests (no external deps beyond Lua)
test: test-unit

test-unit:
	$(LUABIN) tests/test_runner.lua

test-headless:
	$(NVIMBIN) --headless -u NORC -c "luafile tests/runner_headless.lua"

test-lsp:
	$(NVIMBIN) --headless -u NORC -c "luafile tests/runner_headless_real_lsp.lua"

test-c:
	$(NVIMBIN) --headless -u NORC -c "luafile tests/c/run_c_tests.lua"
	$(NVIMBIN) --headless -u NORC -c "luafile tests/c/run_stress_tests.lua"

test-rust:
	$(NVIMBIN) --headless -u NORC -c "luafile tests/rust/run_rust_tests.lua"

test-javascript:
	$(NVIMBIN) --headless -u NORC -c "luafile tests/run_javascript_tests.lua"

# Full matrix (unit + headless + real LSP for lua/c/rust/javascript)
test-all:
	bash tests/run_all_tests.sh

install:
	@echo "Install by symlinking this directory into your Neovim pack path:"
	@echo "  ln -s $$(pwd) ~/.local/share/nvim/site/pack/calltree/start/calltree.nvim"

clean:
	rm -f *.lua.bak tests/*.lua.bak
	rm -rf tests/fixtures/rust_test/target
	rm -rf tests/javascript_project/node_modules
