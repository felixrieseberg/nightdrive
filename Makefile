PRODUCT := Nightdrive
APP_NAME := Nightdrive
CONFIG ?= debug
DIST_APP := dist/$(APP_NAME).app
DEMO_LIB := .scratch/demo-library
DEMO_IPOD := .scratch/demo-ipod
SWIFT_JOBS ?=
SWIFTPM := $(if $(SWIFT_JOBS),env NIGHTDRIVE_SWIFT_JOBS=$(SWIFT_JOBS)) node scripts/run-swiftpm.mjs
SWIFT_BUILD_FLAGS ?=
export DEVELOPMENT_TOOLS
DEVELOPMENT_TOOLS_SWIFT_FLAGS := \
	$(if $(and $(DEVELOPMENT_TOOLS),$(filter release,$(CONFIG))),-Xswiftc -DNIGHTDRIVE_DEVELOPMENT_TOOLS)

# The unit suite runs a process per test case across the machine, which is
# roughly three times quicker than one process running them in order. Set
# TEST_PARALLEL=0 for a single ordered process when a failure needs reading in
# sequence.
TEST_PARALLEL ?= 1
TEST_PARALLEL_FLAG := $(if $(filter-out 0,$(TEST_PARALLEL)),--parallel)

.DEFAULT_GOAL := help

.PHONY: help format lint localizations verify-localizations verify-localized-errors build check verify-fast test verify-test \
	verify-full verify unit-test verification-tooling-test release-version-test app-metadata-test \
	verification-cache-status \
	verification-cache-prune app package release developerid appcast publish ship unship \
	run open close demo demo-run \
	e2e snapshots snapshots-settings sizzle demo-video benchmark-performance benchmark-idle benchmark-library clean icon xcode macos macos-release

help:
	@printf "Nightdrive commands\n\n"
	@printf "  make format       Format Swift sources and tests\n"
	@printf "  make lint         Strictly check Swift formatting\n"
	@printf "  make localizations Update the String Catalog from compiler-extracted UI keys\n"
	@printf "  make verify-localizations Fail if compiler extraction would change the catalog\n"
	@printf "  make verify-localized-errors Reject new raw LocalizedError descriptions\n"
	@printf "  make build        Compile the Swift package (CONFIG=debug|release)\n"
	@printf "  make check        Alias for the fast verification tier\n"
	@printf "  make verify-fast  Lint, test the tooling, and compile\n"
	@printf "  make test         Build tests once, then run them (TEST_FILTER=optional)\n"
	@printf "  make verify-test  Test the Swift package and SwiftPM tooling\n"
	@printf "  make unit-test    Run the unit tests without building first\n"
	@printf "  make verify-full  Lint and tooling, then unit, CLI e2e and GUI checks together\n"
	@printf "  make app          Build dist/$(APP_NAME).app (CONFIG=debug|release)\n"
	@printf "  make package      Alias for make app\n"
	@printf "  make release      Build a release app bundle (no Develop menu)\n"
	@printf "  make release DEVELOPMENT_TOOLS=1  Release build that keeps the Develop menu\n"
	@printf "  make developerid  Build a notarized direct-download zip from the tag at HEAD\n"
	@printf "  make appcast      Generate the Sparkle appcast from the tag at HEAD\n"
	@printf "  make publish      Upload the zip and appcast to the public releases repo\n"
	@printf "  make ship         Build, test-gate, then publish; requires RELEASE_TAG=v<version>+<build>\n"
	@printf "  make unship       Undo a release (RELEASE_TAG=v<version>+<build>)\n"
	@printf "  make run          Close this checkout's app, then build and launch it\n"
	@printf "  make open         Close this checkout's app, then build and launch it\n"
	@printf "  make close        Close only the app staged by this checkout\n"
	@printf "  make demo         Recreate the demo library and fake iPod\n"
	@printf "  make demo-run     Build and launch with the fake library and iPod\n"
	@printf "  make e2e          Run the CLI sync-engine end-to-end checks\n"
	@printf "  make snapshots    Render the GUI snapshot tour\n"
	@printf "  make snapshots-settings  Render only the Settings window shots\n"
	@printf "  make sizzle       Record the ~60s demo video (appears on screen; MP4 in ~/Movies)\n"
	@printf "  make demo-video   Encode the newest sizzle recording into the website clip\n"
	@printf "  make benchmark-performance  Measure release-build CPU and memory, idle and playing\n"
	@printf "  make benchmark-idle  Measure the idle subset of the performance benchmark\n"
	@printf "  make benchmark-library  Measure synthetic 20k/50k/100k library scans and indexes\n"
	@printf "  make xcode        Open Package.swift in Xcode\n"
	@printf "  make verification-cache-status Show shared Swift module-cache usage\n"
	@printf "  make verification-cache-prune  Remove unused cache generations\n"
	@printf "  make clean        Remove local SwiftPM, app, and test build outputs\n"

format:
	node scripts/swift-format.mjs format

lint:
	node scripts/swift-format.mjs lint

localizations: verify-localized-errors
	./scripts/localizations.sh update

verify-localizations: verify-localized-errors
	./scripts/localizations.sh verify

verify-localized-errors:
	./scripts/verify-localized-errors.sh

verification-tooling-test: release-version-test app-metadata-test
	node --test scripts/localized-error-policy.test.mjs scripts/run-swiftpm.test.mjs scripts/swift-format.test.mjs

release-version-test:
	./scripts/release-version.test.sh

app-metadata-test:
	./scripts/app-metadata.test.sh

# Every debug build is the fast one: the wrapper drops debug information
# unless NIGHTDRIVE_DEBUG_INFO_FORMAT asks for it, and it does so for the test,
# e2e and snapshot builds too, so alternating between targets never recompiles
# the executable.
build:
	$(SWIFTPM) build -c $(CONFIG) $(SWIFT_BUILD_FLAGS) $(DEVELOPMENT_TOOLS_SWIFT_FLAGS)

verify-fast: lint verification-tooling-test verify-localized-errors build

check: verify-fast

test: verify-test

verify-test: verification-tooling-test
	$(SWIFTPM) build --build-tests -c $(CONFIG)
	@$(MAKE) --no-print-directory unit-test

# The test run on its own, for callers that have already built. verify-full
# builds every stage's binaries up front so the stages don't queue behind each
# other on the wrapper's build slots.
unit-test:
	NIGHTDRIVE_LOUDNESS_CACHE="$(CURDIR)/.scratch/tests/loudness-cache" \
	NIGHTDRIVE_APP_DATA_DIR="$(CURDIR)/.scratch/test-app-data" \
	NIGHTDRIVE_TRANSCODE_HANDOFF_ROOT="$(CURDIR)/.scratch/tests/transcode-handoffs" \
		$(SWIFTPM) test --skip-build -c $(CONFIG) $(TEST_PARALLEL_FLAG) \
		$(if $(TEST_FILTER),--filter "$(TEST_FILTER)")

verify-full:
	./scripts/verify-full.sh

verify: verify-full

verification-cache-status:
	node scripts/run-swiftpm.mjs cache-status

verification-cache-prune:
	NIGHTDRIVE_CACHE_MAX_AGE_DAYS=$(if $(NIGHTDRIVE_CACHE_MAX_AGE_DAYS),$(NIGHTDRIVE_CACHE_MAX_AGE_DAYS),14) \
		node scripts/run-swiftpm.mjs cache-prune

app:
	./scripts/build-app.sh "$(CONFIG)"

package: app

release:
	$(MAKE) app CONFIG=release

# Direct-download release: a notarized, stapled zip plus Sparkle update
# metadata. NOTARY_PROFILE names credentials created once with
# `xcrun notarytool store-credentials nightdrive-notary`; SPARKLE_PUBLIC_ED_KEY
# is the public half of the key pair from Sparkle's generate_keys (the private
# key never leaves the login keychain). The annotated release tag at HEAD
# supplies both bundle version values; Sparkle compares the build component.
# See DISTRIBUTION.md.
DEVELOPER_ID_APP_IDENTITY ?= Developer ID Application: Felix Rieseberg (LT94ZKYDCJ)
NOTARY_PROFILE ?= nightdrive-notary
SPARKLE_PUBLIC_ED_KEY ?=

developerid:
	APP_SIGN_IDENTITY="$(DEVELOPER_ID_APP_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	./scripts/package-developer-id.sh

appcast:
	DOWNLOAD_URL_PREFIX="$(DOWNLOAD_URL_PREFIX)" ./scripts/generate-appcast.sh

publish:
	./scripts/publish-release.sh

# Full release: preflight, notarized zip, appcast, local test gate, dev-repo
# tag, public GitHub release. RELEASE_TAG proposes v<version>+<build>; the
# annotated tag is created only after the artifacts validate. SHIP_FLAGS
# forwards release.sh flags (--dry-run, --allow-dirty for dry runs, --force,
# --yes):
#
#   SPARKLE_PUBLIC_ED_KEY=… make ship RELEASE_TAG=v1.0.0+2 SHIP_FLAGS=--dry-run
#   SPARKLE_PUBLIC_ED_KEY=… make ship RELEASE_TAG=v1.0.0+2
RELEASE_TAG ?=
ship:
	DEVELOPER_ID_APP_IDENTITY="$(DEVELOPER_ID_APP_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	RELEASE_TAG="$(RELEASE_TAG)" ./scripts/release.sh $(SHIP_FLAGS)

# Undo a published release: pull the public GitHub release (which rolls the
# Sparkle feed back), delete the tags, and remove local artifacts.
# UNSHIP_FLAGS forwards --dry-run and --yes.
unship:
	RELEASE_TAG="$(RELEASE_TAG)" ./scripts/undo-release.sh $(UNSHIP_FLAGS)

run: close app
	open -n "$(DIST_APP)"

open: close app
	open -n "$(DIST_APP)"

close:
	./scripts/close-running-app.sh

demo: build
	rm -rf "$(DEMO_LIB)" "$(DEMO_IPOD)"
	@BIN_PATH="$$(node scripts/run-swiftpm.mjs build -c "$(CONFIG)" --show-bin-path)"; \
		"$$BIN_PATH/$(PRODUCT)" seed-demo "$(DEMO_LIB)" "$(DEMO_IPOD)"

demo-run: close app
	@$(MAKE) app CONFIG="$(CONFIG)"
	@if [ ! -d "$(DEMO_LIB)" ] || [ ! -d "$(DEMO_IPOD)" ]; then \
		"$(CURDIR)/$(DIST_APP)/Contents/MacOS/$(PRODUCT)" \
			seed-demo "$(DEMO_LIB)" "$(DEMO_IPOD)"; \
	fi
	NIGHTDRIVE_LIBRARY="$(CURDIR)/$(DEMO_LIB)" \
	NIGHTDRIVE_EXTRA_VOLUMES="$(CURDIR)/$(DEMO_IPOD)" \
		"$(CURDIR)/$(DIST_APP)/Contents/MacOS/$(PRODUCT)" \
		</dev/null >/dev/null 2>&1 &

e2e:
	./scripts/e2e.sh

snapshots:
	./scripts/snapshots.sh

snapshots-settings:
	./scripts/snapshots.sh --settings

sizzle:
	./scripts/sizzle.sh

demo-video:
	./scripts/encode-demo-video.sh $(DEMO_VIDEO_INPUT)

benchmark-performance:
	./scripts/benchmark-performance.sh "$(if $(BENCHMARK_CONFIG),$(BENCHMARK_CONFIG),release)"

benchmark-idle:
	PERFORMANCE_BENCHMARK_CASES=idle \
		./scripts/benchmark-performance.sh "$(if $(BENCHMARK_CONFIG),$(BENCHMARK_CONFIG),release)"

benchmark-library:
	./scripts/benchmark-library.sh "$(if $(BENCHMARK_CONFIG),$(BENCHMARK_CONFIG),release)"

clean:
	node scripts/run-swiftpm.mjs package clean
	rm -rf dist .scratch/e2e .scratch/snapshots .scratch/tests \
		.scratch/demo-videos .scratch/sizzle-loudness-cache
	rm -rf .scratch/snapshot-runs-* .scratch/verify-full-*

icon:
	rm -rf .scratch/AppIcon.icns .scratch/AppIcon.iconset .scratch/icon-1024.png
	mkdir -p .scratch/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s Resources/AppIcon-1024.png \
			--out ".scratch/AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
		d=$$((s * 2)); \
		sips -z $$d $$d Resources/AppIcon-1024.png \
			--out ".scratch/AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	iconutil -c icns .scratch/AppIcon.iconset -o .scratch/AppIcon.icns
	@echo "Wrote .scratch/AppIcon.icns"

xcode:
	open Package.swift

macos: run

macos-release: release
