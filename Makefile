# Makefile for common developer tasks

.PHONY: help apply-retry ci-check lint clean

help:
	@echo "Makefile targets:"
	@echo "  make apply-retry      - Run ./scripts/out_of_capacity.sh with default arguments"
	@echo "  make ci-check         - Run repository safety checks (backend file not committed)"
	@echo "  make lint             - Run shellcheck locally if installed"
	@echo "  make clean            - Remove helper logs"

apply-retry:
	@echo "Running out-of-capacity apply helper..."
	./scripts/out_of_capacity.sh

ci-check:
	@echo "Running CI safety checks..."
	./scripts/check_no_backend_files.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || (echo "shellcheck not found; install it or use the CI action" && exit 1)
	@shellcheck scripts/*.sh setup_oci_terraform.sh

clean:
	@echo "Cleaning logs..."
	@rm -f scripts/out_of_capacity.log || true
