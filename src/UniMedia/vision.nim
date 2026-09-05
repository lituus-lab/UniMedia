# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Local semantic index with an explicit Ollama embedding adapter.

import std/[algorithm, base64, httpclient, json, math, os, sequtils, streams, strutils,
  uri]
import db_connector/db_sqlite
import UniMedia/[store, types, thumbnails]

const MaxVisionResponseBytes* = 16 * 1024 * 1024

proc boundedBody(response: Response): string =
  ## At most `MaxVisionResponseBytes`, read a chunk at a time.
  ##
  ## `response.body` reads the whole body first and the size check ran after
  ## it, so a server answering with a gigabyte was believed for a gigabyte
  ## before being refused. Reading one byte past the limit is what lets the
  ## caller tell "at the limit" from "over it".
  let stream = response.bodyStream
  var chunk = newString(64 * 1024)
  while result.len <= MaxVisionResponseBytes:
    let read = stream.readData(addr chunk[0], chunk.len)
    if read <= 0: break
    result.add(chunk[0 ..< min(read, MaxVisionResponseBytes + 1 - result.len)])

proc validateVector(values: openArray[float]) =
  if values.len == 0 or values.len > 65_536:
    raise newException(ValueError, "embedding dimensions are outside valid ranges")
  var norm = 0.0
  for value in values:
    if value.classify in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "embedding contains a non-finite value")
    norm += value * value
  if norm <= 0:
    raise newException(ValueError, "embedding norm must be positive")

proc vectorJson(values: openArray[float]): string =
  var node = newJArray()
  for value in values: node.add %value
  $node

proc parseVector(raw: string): seq[float] =
  let node = parseJson(raw)
  if node.kind != JArray:
    raise newException(ValueError, "stored embedding is not an array")
  for value in node:
    if value.kind notin {JInt, JFloat}:
      raise newException(ValueError, "stored embedding contains a non-number")
    result.add value.getFloat()
  validateVector(result)

proc storeVisionDocument*(store: Store; itemId: int64; model, caption: string;
                          labels: openArray[string]; embedding: openArray[float]) =
  discard store.getItem(itemId)
  let cleanModel = model.strip
  if cleanModel.len == 0 or cleanModel.len > 200:
    raise newException(ValueError, "vision model must contain 1 to 200 characters")
  if caption.len > 100_000:
    raise newException(ValueError, "vision caption is too large")
  validateVector(embedding)
  var labelNode = newJArray()
  for label in labels:
    let clean = label.strip
    if clean.len == 0 or clean.len > 200:
      raise newException(ValueError, "vision labels must contain 1 to 200 characters")
    labelNode.add %clean
  store.db.exec(sql"""
    INSERT INTO vision_documents(item_id,model,caption,labels_json,
      embedding_json,dimensions,updated_at) VALUES(?,?,?,?,?,?,?)
    ON CONFLICT(item_id,model) DO UPDATE SET caption=excluded.caption,
      labels_json=excluded.labels_json,embedding_json=excluded.embedding_json,
      dimensions=excluded.dimensions,updated_at=excluded.updated_at""", itemId,
      cleanModel, caption, $labelNode, vectorJson(embedding), embedding.len,
          isoNow())

proc cosine(a, b: openArray[float]): float =
  if a.len != b.len: return -1
  var dot, aa, bb = 0.0
  for index in 0 ..< a.len:
    dot += a[index] * b[index]
    aa += a[index] * a[index]
    bb += b[index] * b[index]
  if aa <= 0 or bb <= 0: return -1
  dot / sqrt(aa * bb)

proc semanticSearch*(store: Store; model: string; query: openArray[float];
                     limit = 50): seq[VisionHit] =
  validateVector(query)
  if limit notin 1..1000:
    raise newException(ValueError, "vision result limit must be between 1 and 1000")
  for row in store.db.fastRows(sql"""
      SELECT v.item_id,i.rel_path,v.caption,v.labels_json,v.embedding_json
      FROM vision_documents v JOIN items i ON i.id=v.item_id
      WHERE v.model=? AND i.deleted_at IS NULL""", model):
    let vector = parseVector(row[4])
    if vector.len != query.len: continue
    let labels = parseJson(row[3]).getElems().mapIt(it.getStr())
    result.add VisionHit(itemId: row[0].parseBiggestInt(), relPath: row[1],
      caption: row[2], labels: labels, score: cosine(query, vector))
  result.sort(proc(a, b: VisionHit): int =
    result = cmp(b.score, a.score)
    if result == 0: result = cmp(a.itemId, b.itemId))
  if result.len > limit: result.setLen(limit)

proc storeVisionAnnotation*(store: Store; itemId: int64; model, caption: string;
                            labels: openArray[string]): VisionAnnotation =
  discard store.getItem(itemId)
  let cleanModel = model.strip
  let cleanCaption = caption.strip
  if cleanModel.len == 0 or cleanModel.len > 200:
    raise newException(ValueError, "vision model must contain 1 to 200 characters")
  if cleanCaption.len == 0 or cleanCaption.len > 100_000:
    raise newException(ValueError, "vision caption must contain 1 to 100000 characters")
  var node = newJArray()
  var cleanLabels: seq[string]
  for label in labels:
    let clean = label.strip
    if clean.len == 0 or clean.len > 200:
      raise newException(ValueError, "vision labels must contain 1 to 200 characters")
    node.add %clean
    cleanLabels.add clean
  if cleanLabels.len > 1000:
    raise newException(ValueError, "vision annotation has too many labels")
  result = VisionAnnotation(itemId: itemId, model: cleanModel,
    caption: cleanCaption, labels: cleanLabels, updatedAt: isoNow())
  store.db.exec(sql"""
    INSERT INTO vision_annotations(item_id,model,caption,labels_json,updated_at)
    VALUES(?,?,?,?,?) ON CONFLICT(item_id,model) DO UPDATE SET
      caption=excluded.caption,labels_json=excluded.labels_json,
      updated_at=excluded.updated_at""", itemId, cleanModel, cleanCaption,
      $node, result.updatedAt)

proc listVisionAnnotations*(store: Store; itemId = 0'i64): seq[
    VisionAnnotation] =
  let query = if itemId > 0: sql"""SELECT item_id,model,caption,labels_json,
    updated_at FROM vision_annotations WHERE item_id=? ORDER BY model"""
    else: sql"""SELECT item_id,model,caption,labels_json,updated_at
      FROM vision_annotations ORDER BY item_id,model"""
  let params = if itemId > 0: @[$itemId] else: @[]
  for row in store.db.fastRows(query, params):
    let labels = parseJson(row[3]).getElems().mapIt(it.getStr())
    result.add VisionAnnotation(itemId: row[0].parseBiggestInt(), model: row[1],
      caption: row[2], labels: labels, updatedAt: row[4])

proc ollamaEmbedding*(endpoint, model, input: string;
                      timeoutMs = 30_000): seq[float] =
  let parsed = parseUri(endpoint)
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
    raise newException(ValueError, "Ollama endpoint must be an explicit HTTP URL")
  if model.strip.len == 0 or input.len == 0:
    raise newException(ValueError, "Ollama model and input must not be empty")
  var client = newHttpClient(timeout = timeoutMs, maxRedirects = 0)
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let response = client.request(endpoint.strip(chars = {'/'}) & "/api/embed",
      httpMethod = HttpPost, body = $(%*{"model": model, "input": input}))
    if response.code != Http200:
      raise newException(IOError, "Ollama embedding request failed: " &
        $response.code)
    let body = response.boundedBody
    if body.len == 0 or body.len > MaxVisionResponseBytes:
      raise newException(IOError, "Ollama response is empty or too large")
    let root = parseJson(body)
    if root.kind != JObject or not root.hasKey("embeddings") or
        root["embeddings"].kind != JArray or root["embeddings"].len != 1:
      raise newException(IOError, "Ollama returned an invalid embedding response")
    for value in root["embeddings"][0]: result.add value.getFloat()
    validateVector(result)
  finally:
    client.close()

proc indexVisionText*(store: Store; itemId: int64; endpoint, model, text,
                      caption: string; labels: openArray[string]) =
  let embedding = ollamaEmbedding(endpoint, model, text)
  store.storeVisionDocument(itemId, model, caption, labels, embedding)

proc semanticTextSearch*(store: Store; endpoint, model, query: string;
                         limit = 50): seq[VisionHit] =
  store.semanticSearch(model, ollamaEmbedding(endpoint, model, query), limit)

proc parseOllamaDescription*(raw: string): tuple[caption: string;
    labels: seq[string]] =
  let root = parseJson(raw)
  if root.kind != JObject or not root.hasKey("caption") or
      root["caption"].kind != JString or not root.hasKey("labels") or
      root["labels"].kind != JArray:
    raise newException(IOError, "Ollama description has an invalid shape")
  result.caption = root["caption"].getStr().strip
  if result.caption.len == 0 or result.caption.len > 100_000:
    raise newException(IOError, "Ollama caption is empty or too large")
  if root["labels"].len > 1000:
    raise newException(IOError, "Ollama returned too many labels")
  for label in root["labels"]:
    if label.kind != JString:
      raise newException(IOError, "Ollama label is not text")
    let clean = label.getStr().strip
    if clean.len == 0 or clean.len > 200:
      raise newException(IOError, "Ollama label is empty or too large")
    result.labels.add clean

proc ollamaDescribe*(endpoint, model, imagePath: string;
                     timeoutMs = 60_000): tuple[caption: string;
    labels: seq[string]] =
  let parsed = parseUri(endpoint)
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
    raise newException(ValueError, "Ollama endpoint must be an explicit HTTP URL")
  if model.strip.len == 0:
    raise newException(ValueError, "Ollama vision model must not be empty")
  let size = getFileSize(imagePath)
  if size <= 0 or size > 32 * 1024 * 1024:
    raise newException(ValueError, "vision input is empty or exceeds 32 MiB")
  let schema = %*{"type": "object", "properties": {
    "caption": {"type": "string"},
    "labels": {"type": "array", "items": {"type": "string"}}},
    "required": ["caption", "labels"]}
  let body = %*{"model": model,
    "prompt": "Describe this media factually in one concise sentence and return a short list of visible labels. Do not identify people.",
    "images": [encode(readFile(imagePath))], "stream": false,
    "format": schema}
  var client = newHttpClient(timeout = timeoutMs, maxRedirects = 0)
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let response = client.request(endpoint.strip(chars = {'/'}) &
        "/api/generate",
      httpMethod = HttpPost, body = $body)
    if response.code != Http200:
      raise newException(IOError, "Ollama description request failed: " &
        $response.code)
    let responseBody = response.boundedBody
    if responseBody.len == 0 or responseBody.len > MaxVisionResponseBytes:
      raise newException(IOError, "Ollama response is empty or too large")
    let root = parseJson(responseBody)
    if root.kind != JObject or not root.hasKey("response") or
        root["response"].kind != JString:
      raise newException(IOError, "Ollama returned an invalid description response")
    result = parseOllamaDescription(root["response"].getStr())
  finally:
    client.close()

proc describeVisionItem*(store: Store; itemId: int64; endpoint,
                         model: string): VisionAnnotation =
  let thumbnail = store.ensureThumbnail(itemId, 1024)
  let description = ollamaDescribe(endpoint, model, thumbnail.path)
  store.storeVisionAnnotation(itemId, model, description.caption,
    description.labels)
