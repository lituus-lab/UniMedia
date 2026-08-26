// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab

import Foundation
import Vision

enum DetectorError: Error {
  case usage
  case noResults
}

func argument(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name),
        index + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[index + 1]
}

do {
  guard let input = argument("--input"), let output = argument("--output") else {
    throw DetectorError.usage
  }
  let request = VNDetectFaceRectanglesRequest()
  let handler = VNImageRequestHandler(url: URL(fileURLWithPath: input),
                                      options: [:])
  try handler.perform([request])
  let observations = request.results ?? []
  let payload: [[String: Any]] = observations.map { observation in
    let box = observation.boundingBox
    return [
      "x": box.minX,
      "y": 1.0 - box.maxY,
      "width": box.width,
      "height": box.height,
      "confidence": observation.confidence,
      "detector": "apple-vision-face-rectangles-v1"
    ]
  }
  let data = try JSONSerialization.data(withJSONObject: payload,
                                        options: [.sortedKeys])
  try data.write(to: URL(fileURLWithPath: output), options: [.atomic])
} catch DetectorError.usage {
  FileHandle.standardError.write(Data(
    "usage: unimedia-apple-vision --input FILE --output JSON\n".utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data("face detection failed: \(error)\n".utf8))
  exit(1)
}

