<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0006: Store validated smart-album rules, not SQL

## Status

Accepted.

## Context

The previous application serialized JSON rules and compiled them through SQL
string concatenation. That design allowed injection, silently accepted unknown
fields and coupled persisted data to one schema layout.

## Decision

Schema v6 stores smart albums and ordered rules in normalized tables. The
engine validates every field, operator and value before insertion. Supported
v1 fields are path, title, description, keyword, rating, favorite, date and
media kind. Albums require one through twenty rules.

Each rule is evaluated through a fixed query with bound values. Keyword arrays
are decoded with `std/json`, avoiding a runtime dependency on SQLite JSON1.
Match-all is set intersection and match-any is set union. Membership remains a
dynamic projection and is never materialized.

## Consequences

Stored data cannot inject SQL and unknown future rules fail closed. Evaluation
does more small queries than a generated monolithic statement, which is an
acceptable v1 tradeoff for auditability and portability. A future query planner
may optimize execution without changing the persisted rule contract.
