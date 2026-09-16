.PHONY: check server macos run
check:
	./scripts/test.sh
server:
	./scripts/dev-server.sh
macos:
	xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

run:
	./scripts/dev-macos.sh
