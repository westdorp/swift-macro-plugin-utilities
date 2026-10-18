SWIFT ?= swift
PYTHON ?= python3
STRICT_TEST_FLAGS := --sanitize=thread -Xswiftc -strict-concurrency=complete

.PHONY: test test-guardrails test-dependency-owners test-strict build

test: test-guardrails test-dependency-owners test-strict

test-guardrails:
	./Scripts/check-test-guardrails.sh

# Non-test targets may reach only swiftlang, apple, and westdorp packages.
test-dependency-owners:
	$(PYTHON) -I -B Scripts/Tests/test_check_dependency_owners.py
	./Scripts/check-dependency-owners.py --swift "$(SWIFT)"

test-strict:
	$(SWIFT) test $(STRICT_TEST_FLAGS)

build:
	$(SWIFT) build -Xswiftc -strict-concurrency=complete
