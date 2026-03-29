#!/bin/bash
# Generate BuildVersion.swift with the current git commit hash.
# Add this as a "Run Script" build phase in Xcode (before Compile Sources).

HASH=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
OUTPUT="${SRCROOT}/AnxietyWatch/Utilities/BuildVersion.swift"

cat > "$OUTPUT" << EOF
// Auto-generated — do not edit
enum BuildVersion {
    static let commitHash = "$HASH"
}
EOF
