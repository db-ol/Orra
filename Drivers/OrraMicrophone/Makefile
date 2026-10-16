# Builds OrraMicrophone.driver with clang, outside Xcode and outside the Orra app.
#
#   make            builds build/OrraMicrophone.driver (arm64 and x86_64), signed ad hoc
#   make test       builds the bundle and runs the loopback test against it, in process
#   make check      lints Info.plist, checks the factory symbol, runs the test
#   make pkg        builds the installer build/OrraMicrophone.pkg (pkg.sh, unsigned unless
#                   the signing variables in pkg.sh are set)
#   make clean      removes build/
#
# Nothing here installs the driver or needs sudo. README.md has the install steps.

NAME        := OrraMicrophone
BUILD       := build
BUNDLE      := $(BUILD)/$(NAME).driver
EXECUTABLE  := $(BUNDLE)/Contents/MacOS/$(NAME)
MIN_MACOS   := 15.6
ARCHS       := -arch arm64 -arch x86_64
CC          := xcrun clang
CFLAGS      := -std=c11 -O2 -Wall -Wextra -Werror -fvisibility=hidden \
               -mmacosx-version-min=$(MIN_MACOS) $(ARCHS)
LDFLAGS     := -bundle -framework CoreAudio -framework CoreFoundation
# Ad hoc signing for a local build. A release signs with the Developer ID instead,
# README.md has the steps.
SIGN_ID     ?= -
SIGN_FLAGS  ?= --timestamp=none

.PHONY: all test check pkg clean

all: $(BUNDLE)

$(BUNDLE): $(NAME).c Info.plist Makefile
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(EXECUTABLE) $(NAME).c
	codesign --force --sign "$(SIGN_ID)" $(SIGN_FLAGS) $(BUNDLE)

$(BUILD)/loopback_test: Tests/loopback_test.c Makefile
	mkdir -p $(BUILD)
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Werror -mmacosx-version-min=$(MIN_MACOS) \
		-framework CoreAudio -framework CoreFoundation -o $@ Tests/loopback_test.c

test: $(BUNDLE) $(BUILD)/loopback_test
	$(BUILD)/loopback_test $(BUNDLE)

check: $(BUNDLE)
	./check.sh

pkg:
	./pkg.sh

clean:
	rm -rf $(BUILD)
