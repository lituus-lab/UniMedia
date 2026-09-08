# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Shell-free: `pwd` and `rm` are unavailable under mingw32-make on Windows.
ifeq ($(origin CC),default)
  ifeq ($(OS),Windows_NT)
    CC := gcc
  else
    CC := cc
  endif
endif

# Overridable: the artifact-consumption job points it at the downloaded zip
# rather than the build tree, and links the same archive from there.
ROOT   := $(CURDIR)/../..
CFLAGS := -I$(ROOT)/include -O2 -Wall -Wextra -Werror -std=c11
LIB    := $(ROOT)/libUniMedia.a

# A static archive carries no transitive link information. SQLite is absent on
# purpose: db_connector binds it with `dynlib`, so the loader resolves it at run
# time and there is nothing to link against -- naming it broke Windows, where
# no sqlite3 import library exists.
ifeq ($(OS),Windows_NT)
  LIBS := 
  BIN  := test_abi.exe
  RUN  := $(BIN)
  RM_F := del /q
else
  UNAME := $(shell uname -s)
  ifeq ($(UNAME),Darwin)
    # std/sysrand reaches Security; UniImage's HEIC path reaches ImageIO.
    LIBS := -framework Security -framework ImageIO \
            -framework CoreFoundation -framework CoreGraphics
  else
    # glibc keeps the maths functions out of libc, and UniAudio's chroma and
    # AIFF code calls them.
    LIBS := -lm
  endif
  BIN  := test_abi
  RUN  := ./$(BIN)
  RM_F := rm -f
endif

# Windows ships SQLite as winsqlite3.dll in System32 and nothing named
# sqlite3_64.dll, which is what db_connector asks the loader for. A copy beside
# the binary is found first, so a consumer with no Nim installation still runs.
# cmd's `copy`, not `cp`: mingw32-make has no shell.
ifeq ($(OS),Windows_NT)
SQLITE := sqlite3_64.dll
$(SQLITE):
	copy "$(WINDIR)\\System32\\winsqlite3.dll" $(SQLITE)
else
SQLITE :=
endif

.PHONY: all run clean
all: run
run: $(BIN) $(SQLITE)
	$(RUN)
$(BIN): test_abi.c $(ROOT)/include/UniMedia.h $(LIB)
	$(CC) $(CFLAGS) -o $(BIN) test_abi.c $(LIB) $(LIBS)
clean:
	-$(RM_F) $(BIN)
