APP_NAME    := KeyMute
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN         := $(CONTENTS)/MacOS/$(APP_NAME)
SOURCES     := $(wildcard Sources/*.swift)
MIN_MACOS   := 13.0
ARCH        := $(shell uname -m)
TARGET      := $(ARCH)-apple-macos$(MIN_MACOS)
SWIFTC      ?= swiftc

# ─── 代码签名身份 ────────────────────────────────────────────────
# 为什么必须固定：ad-hoc 签名的「指定要求」就是二进制的 cdhash，每次重编都变，
# TCC（辅助功能）就当成换了个程序，已授权限全失效。固定证书后「指定要求」变成
# identifier + certificate leaf，重编不影响授权。
#
# 证书与私钥是仓库资产（scripts/signing/，明文），构建时导入项目内钥匙串
# .signing/build.keychain-db（gitignore），不碰登录钥匙串、不弹窗。
#   make cert     一次性生成证书（已提交则不需要）
#   make SIGN=    强制 ad-hoc
SIGN        ?= keymute-dev
SIGN_P12    := scripts/signing/$(SIGN).p12

.PHONY: all build bundle run restart clean install cert ensure-sign icon help

all: bundle

help:
	@echo "make build      编译二进制"
	@echo "make bundle     编译 + 组装 .app + 固定身份签名（默认目标）"
	@echo "make run        编译并启动"
	@echo "make restart    杀掉旧实例后重新启动（换了图标/改代码后用它）"
	@echo "make install    安装到 /Applications"
	@echo "make cert       生成固定签名证书（一次性）"
	@echo "make icon       重新生成 App 图标"
	@echo "make clean      清理 build/"

build: $(BIN)

$(BIN): $(SOURCES) Resources/Info.plist
	@mkdir -p $(CONTENTS)/MacOS
	$(SWIFTC) -O -swift-version 5 -target $(TARGET) \
		-framework AppKit -framework ApplicationServices \
		$(SOURCES) -o $(BIN)

cert:
	@./scripts/signing-cert.sh $(SIGN)

icon:
	@swift -swift-version 5 scripts/gen-icon.swift $(BUILD_DIR)/AppIcon.iconset
	@iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "✅ Resources/AppIcon.icns"

ensure-sign:
	@./scripts/ensure-sign.sh $(SIGN)

bundle: $(BIN)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@mkdir -p $(CONTENTS)/Resources
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@if [ -f "$(SIGN_P12)" ]; then \
		./scripts/ensure-sign.sh "$(SIGN)" && \
		codesign --force --sign "$(SIGN)" $(APP) && \
		echo "🔏 签名：$(SIGN)（固定身份，重编不丢授权）"; \
	else \
		codesign --force --sign - $(APP) && \
		echo "⚠️ 未找到 $(SIGN_P12)，回退 ad-hoc（重编会重新要求授权）。跑 make cert 可根治。"; \
	fi

run: bundle
	@open $(APP)

# 单实例逻辑下 open 只会激活旧进程，换图标/改代码后要先把旧实例杀掉。
restart: bundle
	@-pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@sleep 0.5
	@touch $(APP)
	@open $(APP)

install: bundle
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP) /Applications/
	@echo "✅ 已安装到 /Applications/$(APP_NAME).app"

clean:
	@rm -rf $(BUILD_DIR)
