.PHONY: bootstrap test coverage demo-local demo-sepolia build frontend-build

bootstrap:
	./scripts/bootstrap.sh

build:
	forge build

test:
	forge test -vv

coverage:
	forge coverage --ir-minimum --report summary

frontend-build:
	npm --workspace frontend run build

demo-local:
	./scripts/demo/local.sh

demo-sepolia:
	./scripts/demo/sepolia.sh
