#!/bin/sh
# Compiles the Foundation-only M9Box files with the harness and runs it.
set -e
cd "$(dirname "$0")/../.."
M=iOSClient/M9Box
OUT=${TMPDIR:-/tmp}/m9box-tasks-harness
# M9BoxSyncResult lives in M9BoxCalDav.swift (URLSession), stubbed here.
echo "struct M9BoxSyncResult { var changed: [String]; var removed: [String]; var syncToken: String? }" > "$OUT-stub.swift"
swiftc -o "$OUT" $M/Calendar/M9BoxCalModels.swift $M/Calendar/M9BoxICal.swift $M/Calendar/M9BoxMultiStatus.swift \
  "$OUT-stub.swift" $M/Tasks/M9BoxVTodo.swift Tests/M9BoxTasks/main.swift
"$OUT"
