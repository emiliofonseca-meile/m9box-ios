#!/bin/sh
# Compiles the Foundation-only Meile files with the harness and runs it.
set -e
cd "$(dirname "$0")/../.."
M=iOSClient/Meile
OUT=${TMPDIR:-/tmp}/meile-tasks-harness
# MeileSyncResult lives in MeileCalDav.swift (URLSession), stubbed here.
echo "struct MeileSyncResult { var changed: [String]; var removed: [String]; var syncToken: String? }" > "$OUT-stub.swift"
swiftc -o "$OUT" $M/Calendar/MeileCalModels.swift $M/Calendar/MeileICal.swift $M/Calendar/MeileMultiStatus.swift \
  "$OUT-stub.swift" $M/Tasks/MeileVTodo.swift Tests/MeileTasks/main.swift
"$OUT"
