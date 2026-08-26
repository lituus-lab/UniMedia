<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0010: Optional intelligence and sync boundaries

Status: accepted — 2026-08-01

## Decision

Face storage is backend-neutral: detectors provide normalized rectangles and a
backend identifier, while person names and assignments remain explicit user
decisions. No model, training data or detector implementation is copied or
downloaded by UniMedia.

The detector boundary is an executable receiving `--input FILE --output JSON`.
Execution has a timeout and bounded output; UniMedia computes crop signatures
and clustering itself. The included macOS helper calls Apple's installed Vision
framework and contains no model or third-party detector data.

Semantic records are isolated by model identifier. Embeddings are validated and
ranked locally. Ollama is an optional, explicit HTTP adapter with no implicit
endpoint, redirects or unbounded response. Model licensing remains visible to
the user selecting that model.

Structured captions and labels live separately from semantic vectors because a
multimodal generation model need not expose compatible embeddings. Descriptions
use the shared bounded thumbnail and a JSON schema; they never request or infer
people's identities.

Remote transport uses an installed rclone executable. UniMedia invokes argument
vectors without a shell, never receives credentials, and uses non-deleting
`copy`. Application requires a persisted dry-run plan and explicit confirmation.
Push excludes all library control state; pull targets an isolated internal staging
directory for later journaled import and never overwrites the active catalogue.
The rclone project is MIT-licensed; remote-provider terms remain external.

## Consequences

The Apache-2.0 engine contains original orchestration and storage code only. A
deployment can choose platform-native or separately licensed detector/model and
transport packages without changing the catalogue contracts.
