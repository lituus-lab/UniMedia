# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[sets, strutils]
import db_connector/db_sqlite
import contracts
import UniMedia/[types, store]

func wellFormedBuckets(buckets: seq[TimelineBucket]): bool =
  ## One bucket per period, and grouping cannot produce an empty one.
  var seen = initHashSet[string]()
  for bucket in buckets:
    if bucket.period.len == 0 or bucket.itemCount <= 0 or bucket.totalBytes < 0:
      return false
    if bucket.period in seen: return false
    seen.incl bucket.period
  true

proc parseTimelinePeriod*(value: string): TimelinePeriod =
  case value.toLowerAscii()
  of "day": tpDay
  of "month": tpMonth
  of "year": tpYear
  else: raise newException(ValueError, "invalid timeline period: " & value)

proc timelineReport*(store: Store;
                     by = tpMonth): seq[TimelineBucket] {.contractual.} =
  ensure:
    wellFormedBuckets(result)
  body:
    let rows = case by
      of tpDay: store.db.getAllRows(sql"""
        SELECT substr(creation_date,1,10),count(*),coalesce(sum(file_size),0)
        FROM items WHERE deleted_at IS NULL AND length(creation_date)>=10
        GROUP BY substr(creation_date,1,10)
        ORDER BY substr(creation_date,1,10)""")
      of tpMonth: store.db.getAllRows(sql"""
        SELECT substr(creation_date,1,7),count(*),coalesce(sum(file_size),0)
        FROM items WHERE deleted_at IS NULL AND length(creation_date)>=7
        GROUP BY substr(creation_date,1,7)
        ORDER BY substr(creation_date,1,7)""")
      of tpYear: store.db.getAllRows(sql"""
        SELECT substr(creation_date,1,4),count(*),coalesce(sum(file_size),0)
        FROM items WHERE deleted_at IS NULL AND length(creation_date)>=4
        GROUP BY substr(creation_date,1,4)
        ORDER BY substr(creation_date,1,4)""")
    for row in rows:
      result.add TimelineBucket(period: row[0], itemCount: row[1].parseInt(),
        totalBytes: row[2].parseBiggestInt())
