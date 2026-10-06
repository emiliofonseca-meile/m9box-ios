#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
M=iOSClient/Meile
OUT=${TMPDIR:-/tmp}/meile-tasks-e2e
mkdir -p "$OUT"; cp Tests/MeileTasks/e2e.swift "$OUT/main.swift"
swiftc -o "$OUT/e2e" $M/Calendar/MeileCalModels.swift $M/Calendar/MeileICal.swift $M/Calendar/MeileMultiStatus.swift \
  $M/Calendar/MeileCalDav.swift $M/Tasks/MeileVTodo.swift $M/Tasks/MeileTasksRepository.swift "$OUT/main.swift"
"$OUT/e2e" "$@"
