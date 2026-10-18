SWIFT ?= swift
STRICT_TEST_FLAGS := --sanitize=thread -Xswiftc -strict-concurrency=complete

.PHONY: test test-guardrails test-dependency-owners test-strict build

test: test-guardrails test-dependency-owners test-strict

test-guardrails:
	./Scripts/check-test-guardrails.sh

# Library products may reach only swiftlang, apple, and westdorp packages.
test-dependency-owners:
	python3 -I Scripts/Tests/check_dependency_owners_tests.py
	python3 -I -B Scripts/check-dependency-owners.py --swift "$(SWIFT)"

test-strict:
	$(SWIFT) test $(STRICT_TEST_FLAGS)

build:
	$(SWIFT) build -Xswiftc -strict-concurrency=complete
