PANDOC_DATA_DIR ?= $(HOME)/.local/share/pandoc
PANDOC_CUSTOM_DIR = $(PANDOC_DATA_DIR)/custom
PANDOC_FILE = $(PANDOC_CUSTOM_DIR)/tracwiki.lua

.PHONY: install uninstall test test-reader test-mcp

install:
	mkdir -p "$(PANDOC_CUSTOM_DIR)"
	cp tracwiki.lua "$(PANDOC_FILE)"
	@echo "Installed tracwiki.lua to $(PANDOC_FILE)"
	@echo "Try: pandoc -t tracwiki.lua README.md"

uninstall:
	rm -f "$(PANDOC_FILE)"
	@echo "Removed $(PANDOC_FILE)"

test:
	tests/run_writer_tests.sh
	tests/run_reader_tests.sh

test-reader:
	tests/run_reader_tests.sh

test-mcp:
	mcp/test/run_tests.sh