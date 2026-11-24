#!/usr/bin/env bash
# Offline, synthetic fixtures only. No login, API key, signing or network access.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null
command -v node >/dev/null
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
run_swift() {
  local name="$1"
  shift
  echo "== $name =="
  swiftc -parse-as-library "$@" -o "$work/$name"
  "$work/$name"
}
run_swift parcel-model Shared/Models.swift Tests/ParcelModelTests.swift
run_swift clipboard App/Parser.swift Tests/ClipboardParserTests.swift
run_swift douyin Shared/Models.swift App/Parser.swift App/DouyinImport.swift Tests/DouyinParserTests.swift
run_swift performance Shared/Models.swift Tests/ParcelPerformanceTests.swift
echo "== JD order fixtures =="
node Tests/JDOrdersHookTests.mjs
echo "PASS: all offline regression suites"
