.PHONY: check server macos ios run run-dev release
check:
	./scripts/test.sh
server:
	./scripts/dev-server.sh
macos:
	xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

# Feature 016: the iPhone app and keyboard for an Apple silicon simulator, unsigned.
ios:
	xcodebuild -quiet -project apps/ios/LocalFlowPhone.xcodeproj -scheme LocalFlowPhone -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath build/iOSDerivedData CODE_SIGNING_ALLOWED=NO build

run:
	./scripts/dev-macos.sh

# Installs /Applications/LocalFlow Dev.app beside the everyday app (Feature 014).
run-dev:
	./scripts/dev-macos.sh --dev

# Optimized build, installed and opened the same way as run.
release:
	LOCALFLOW_CONFIGURATION=Release ./scripts/dev-macos.sh
