# FaceUnlock — Xcode 없이 Command Line Tools만으로 .app 을 조립한다.

APP_NAME   := FaceUnlock
BUNDLE_ID  := io.github.kinnch.FaceUnlock

# 버전의 **단일 출처**. Resources/Info.plist 에는 자리표시자만 있고 빌드 때
# 여기 값이 각인된다. 예전에는 plist 에 직접 적혀 있어서, 태그만 v0.1.1 로
# 올리고 plist 는 0.1.0 인 채로 배포되는 일이 실제로 있었다.
# 릴리스 절차: 이 두 줄을 올린다 → make dmg → git tag v$(VERSION)
VERSION    := 0.2.0
BUILD_NUM  := 15
TARGET     := arm64-apple-macos14.0

BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

SOURCES    := $(shell find Sources -name '*.swift')
SWIFT_OPTS := -parse-as-library -target $(TARGET) -swift-version 5

.PHONY: all debug release run clean install sign check aligntest icon model dmg version

all: debug

# 릴리스 스크립트가 태그 이름을 여기서 읽어간다.
version:
	@echo $(VERSION)

debug:   SWIFT_OPTS += -Onone -g
debug:   bundle sign

release: SWIFT_OPTS += -O -whole-module-optimization
release: bundle sign

bundle: $(SOURCES) Resources/Info.plist
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	swiftc $(SWIFT_OPTS) -o $(MACOS_DIR)/$(APP_NAME) $(SOURCES)
	@sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD_NUM)/' \
	    Resources/Info.plist > $(CONTENTS)/Info.plist
	@if [ -d Resources/Models ]; then cp -R Resources/Models $(RES_DIR)/; fi
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(RES_DIR)/; fi
	@echo "APPL????" > $(CONTENTS)/PkgInfo
	@echo "==> built $(APP_BUNDLE)  v$(VERSION) ($(BUILD_NUM))"

# 서명 정체성 선택.
#
# ad-hoc(`-`) 서명의 지정 요구사항은 바이너리 해시 그 자체라서, 다시 빌드할 때마다
# 손쉬운 사용 권한이 조용히 무효가 된다 (시스템 설정에는 체크된 채로 남는다).
# `./scripts/make_signing_cert.sh` 로 자체 서명 인증서를 만들어 두면 요구사항이
# 신원 기반으로 바뀌어 재빌드에도 권한이 유지된다.
#
# Developer ID 가 있다면 직접 덮어쓴다:
#   make release CODESIGN_ID="Developer ID Application: ..."
LOCAL_CERT := FaceUnlock Local Signing
CODESIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$(LOCAL_CERT)" | head -1 | awk '{print $$2}')
ifeq ($(strip $(CODESIGN_ID)),)
CODESIGN_ID := -
endif

sign:
	@codesign --force --sign "$(CODESIGN_ID)" \
	    --entitlements Resources/$(APP_NAME).entitlements \
	    --timestamp=none \
	    $(APP_BUNDLE)
ifeq ($(CODESIGN_ID),-)
	@echo "==> signed ad-hoc  ⚠️  다시 빌드하면 손쉬운 사용 권한이 무효가 됩니다."
	@echo "    한 번만 실행하면 해결됩니다:  ./scripts/make_signing_cert.sh"
else
	@echo "==> signed with '$(LOCAL_CERT)' ($(CODESIGN_ID))"
endif

# 정렬 파이프라인 확인용 CLI. 앱 번들 없이 사진만으로 검증한다.
#   make aligntest && ./build/aligntest photo1.jpg photo2.jpg
ALIGNTEST_SRCS := tools/AlignTest/main.swift tools/AlignTest/SelfTest.swift \
    Sources/FaceUnlock/Core/Log.swift \
    Sources/FaceUnlock/Core/L10n.swift \
    Sources/FaceUnlock/Core/VectorMath.swift \
    Sources/FaceUnlock/Core/FaceGeometry.swift \
    Sources/FaceUnlock/Core/FaceDetector.swift \
    Sources/FaceUnlock/Core/FaceAligner.swift \
    Sources/FaceUnlock/Core/EmbeddingModel.swift \
    Sources/FaceUnlock/Core/LockMonitor.swift

aligntest: $(ALIGNTEST_SRCS)
	@mkdir -p $(BUILD_DIR)
	swiftc -target $(TARGET) -swift-version 5 -Onone -g \
	    -o $(BUILD_DIR)/aligntest $(ALIGNTEST_SRCS)
	@echo "==> built $(BUILD_DIR)/aligntest"

# 앱 아이콘 재생성. 결과물(Resources/AppIcon.icns)은 커밋되어 있으므로
# 디자인을 바꿀 때만 돌리면 된다. 아이콘은 tools/make_icon.swift 가 코드로 그린다.
icon:
	@swift tools/make_icon.swift $(BUILD_DIR)/AppIcon.iconset
	@iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "==> Resources/AppIcon.icns"

# ArcFace 모델 준비. 외부에서 가중치를 내려받으므로 최초 1회만 수동으로 실행한다.
#   가중치는 InsightFace 비상업 연구용 라이선스 — 저장소·배포물에 포함하지 않는다.
model:
	@./scripts/setup_model_env.sh
	@.venv/bin/python tools/fetch_arcface.py

# Swift 전처리 ↔ 원본 ONNX 교차 검증. `make model` 이후 한 번은 돌려야 한다.
xcheck: aligntest
	@FACEUNLOCK_MODEL=Resources/Models/ArcFace.mlpackage \
	    ./build/aligntest --dump-fixture > build/swift_embed.txt
	@.venv/bin/python tools/verify_preprocessing.py

check:
	@codesign -dv --entitlements - $(APP_BUNDLE) 2>&1 | head -20

run: debug
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open $(APP_BUNDLE)
	@echo "==> launched. 로그: make log"

log:
	@log stream --level info --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

install: release
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "==> installed to /Applications/$(APP_NAME).app"

# 배포용 DMG. 열면 배경 화살표 안내가 있는 표준 설치 창이 뜬다 (dmgbuild 로
# 레이아웃을 심는다 — Finder AppleScript 와 달리 자동화 권한 없이 동작).
# 받은 사람은 '설치 도우미 (Install Helper).command' 우클릭 → 열기로 시작한다
# (앱 복사 + quarantine 해제 + 모델 설치 + 실행까지 자동). 무공증 배포라 첫 실행은
# Gatekeeper 가 차단하며, 시스템 설정의 '그래도 열기' 후 다시 열어야 한다 — 이 절차는
# DMG 배경·README 에 안내되어 있다.
#
# **ArcFace 가중치는 뺀다.** InsightFace 사전학습 가중치는 비상업 연구용
# 라이선스라 재배포할 수 없다. 설치 도우미가 공식 배포처에서 직접 내려받아
# ~/Library/Application Support/FaceUnlock/Models/ 에 넣는다.
# 리소스를 빼면 서명이 깨지므로 뺀 뒤 다시 서명한다.
DIST_DIR := dist
dmg: release
	@rm -rf $(DIST_DIR)/staging $(DIST_DIR)/$(APP_NAME).dmg
	@mkdir -p $(DIST_DIR)/staging
	@cp -R $(APP_BUNDLE) $(DIST_DIR)/staging/
	@rm -rf $(DIST_DIR)/staging/$(APP_NAME).app/Contents/Resources/Models
	@codesign --force --sign "$(CODESIGN_ID)" \
	    --entitlements Resources/$(APP_NAME).entitlements \
	    --timestamp=none \
	    $(DIST_DIR)/staging/$(APP_NAME).app
	@cp README.md '$(DIST_DIR)/staging/먼저 읽어주세요 (Read Me).md'
	@mkdir -p $(DIST_DIR)/staging/.tools
	@cp tools/fetch_arcface.py $(DIST_DIR)/staging/.tools/
	@install -m 755 scripts/install_helper.command \
	    '$(DIST_DIR)/staging/설치 도우미 (Install Helper).command'
	@swift tools/make_dmg_background.swift $(BUILD_DIR)/dmg-background.png
	@./scripts/build_dmg.sh $(DIST_DIR)/staging $(BUILD_DIR)/dmg-background.png \
	    $(DIST_DIR)/$(APP_NAME).dmg
	@rm -rf $(DIST_DIR)/staging
	@echo "==> $(DIST_DIR)/$(APP_NAME).dmg  v$(VERSION) (ArcFace 모델 미포함 — 라이선스상 재배포 불가)"
	@echo "    설치: DMG 안 '설치 도우미 (Install Helper).command' 우클릭 → 열기"

clean:
	@rm -rf $(BUILD_DIR)
