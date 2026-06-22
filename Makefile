.PHONY: build run resolve patch clean

# Resolve deps, apply the WebRTC macOS header workaround, then build release.
build: resolve patch
	swift build -c release
	@echo "→ .build/release/screenshare"

resolve:
	swift package resolve

# Must run after resolve and after any `swift package clean` (re-extracts the artifact).
patch:
	./scripts/patch-webrtc-headers.sh

run: build
	.build/release/screenshare start

clean:
	swift package clean
	rm -rf .build
