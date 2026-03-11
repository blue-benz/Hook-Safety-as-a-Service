.PHONY: bootstrap test coverage demo-local demo-sepolia demo-sepolia-live-reactive build frontend-build deploy-sepolia

bootstrap:
	./scripts/bootstrap.sh

build:
	forge build

test:
	forge test -vv

coverage:
	./scripts/check-coverage.sh

deploy-sepolia:
	./scripts/deploy/unichain.sh

frontend-build:
	npm --workspace frontend run build

demo-local:
	./scripts/demo/local.sh

demo-sepolia:
	./scripts/demo/sepolia.sh

demo-sepolia-live-reactive:
	./scripts/demo/sepolia-live-reactive.sh
