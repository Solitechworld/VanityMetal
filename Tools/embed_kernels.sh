#!/usr/bin/env bash
#
# Regenerates Sources/VanityMetalCore/MetalShaderSource.swift from
# Kernels/VanityKernels.metal.
#
# The shader is embedded as a Swift string rather than shipped as a resource
# so the app has exactly one file to load and works unchanged whether it is
# built with SwiftPM, dropped into an Xcode project, or run from a bundle.
# It is compiled at launch with MTLDevice.makeLibrary(source:options:) and the
# result is cached, which costs about a second the first time and nothing after.
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Kernels/VanityKernels.metal
OUT=Sources/VanityMetalCore/MetalShaderSource.swift

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

{
  echo "//"
  echo "//  MetalShaderSource.swift"
  echo "//  GENERATED FILE — do not edit."
  echo "//  Regenerate with: Tools/embed_kernels.sh"
  echo "//  Source of truth: Kernels/VanityKernels.metal"
  echo "//"
  echo ""
  echo "public enum MetalShaderSource {"
  echo "    public static let source: String = #\"\"\""
  cat "$SRC"
  echo "\"\"\"#"
  echo "}"
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines)"
