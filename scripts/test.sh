#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache build/tests
COMMON=(
    Sources/PortBar/Models/*.swift
    Sources/PortBar/Helpers/AskpassHelper.swift
    Sources/PortBar/Services/*.swift
    Sources/PortBar/Automation/*.swift
)
swiftc -module-cache-path .cache -Xcc -fmodules-cache-path=.cache \
    "${COMMON[@]}" Tests/PortBarTests/main.swift -o build/tests/model-tests
./build/tests/model-tests
swiftc -module-cache-path .cache -Xcc -fmodules-cache-path=.cache \
    "${COMMON[@]}" Tests/AutomationTests/main.swift -o build/tests/automation-tests
./build/tests/automation-tests
python3 Tests/AutomationTests/integration.py
