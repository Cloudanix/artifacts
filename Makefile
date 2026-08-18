# =============================================================================
# JIT Setup Orchestrator — Makefile
# =============================================================================

.PHONY: test test-unit test-integration test-all lint check help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

test: test-unit test-integration ## Run all tests

test-unit: ## Run unit tests
	@echo "━━━ Unit Tests ━━━"
	@bats tests/unit/*.bats

test-integration: ## Run integration tests
	@echo "━━━ Integration Tests ━━━"
	@bats tests/integration/*.bats

test-all: test ## Alias for 'test'

lint: ## Check bash syntax on all scripts
	@echo "━━━ Syntax Check ━━━"
	@find lib aws-jit-db aws-jit-vm aws-jit-eks -name "*.sh" -exec bash -n {} \; -print
	@echo ""
	@echo "✓ All scripts pass syntax validation"

check: lint test ## Run lint + all tests
	@echo ""
	@echo "✓ All checks passed"
