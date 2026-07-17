SWIFT ?= swift
STRICT_TEST_FLAGS := --sanitize=thread -Xswiftc -strict-concurrency=complete

.PHONY: test test-guardrails test-strict build

test: test-guardrails test-strict

test-guardrails:
	./Scripts/check-test-guardrails.sh

test-strict:
	$(SWIFT) test $(STRICT_TEST_FLAGS)

build:
	$(SWIFT) build -Xswiftc -strict-concurrency=complete
