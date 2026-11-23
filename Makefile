APP      := build/Peek.app
INSTALL  := $(HOME)/Applications/Peek.app
VERSION  := $(shell cat VERSION)

.PHONY: build install run uninstall cert previews icon zip clean

build:            ## Build build/Peek.app
	./build.sh

install: build    ## Build and copy to ~/Applications
	@pkill -f "$(INSTALL)/Contents/MacOS/Peek" 2>/dev/null || true
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(INSTALL)"
	cp -R "$(APP)" "$(INSTALL)"
	@echo "Installed to $(INSTALL)"

run: install      ## Build, install and launch
	open "$(INSTALL)"

uninstall:        ## Remove Peek's Claude hooks and the installed app
	@if [ -x "$(INSTALL)/Contents/MacOS/Peek" ]; then "$(INSTALL)/Contents/MacOS/Peek" --uninstall-hooks; fi
	@pkill -f "$(INSTALL)/Contents/MacOS/Peek" 2>/dev/null || true
	rm -rf "$(INSTALL)"
	@echo "Peek removed. Your settings (defaults domain dev.peek.notch) were kept."

cert:             ## Create a local signing certificate so permissions survive rebuilds
	./scripts/create-signing-cert.sh

previews:         ## Re-render the README screenshots from the real views
	swift build -c release
	"$$(swift build -c release --show-bin-path)/Peek" --render-previews docs/images

icon:             ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift

zip: build        ## Package build/Peek-<version>.zip for a release
	cd build && ditto -c -k --keepParent Peek.app "Peek-$(VERSION).zip"
	@echo "build/Peek-$(VERSION).zip"

clean:            ## Remove build output
	rm -rf .build build
