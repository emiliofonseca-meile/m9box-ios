#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
M=iOSClient/M9Box
OUT=${TMPDIR:-/tmp}/m9box-tasks-e2e
mkdir -p "$OUT"; cp Tests/M9BoxTasks/e2e.swift "$OUT/main.swift"
swiftc -o "$OUT/e2e" $M/Calendar/M9BoxCalModels.swift $M/Calendar/M9BoxICal.swift $M/Calendar/M9BoxMultiStatus.swift \
  $M/Calendar/M9BoxCalDav.swift $M/Tasks/M9BoxVTodo.swift $M/Tasks/M9BoxTasksRepository.swift "$OUT/main.swift"
"$OUT/e2e" "$@"
