#!/bin/sh
# Xcode toolchain provides Swift Testing directly.
cd "$(dirname "$0")" && exec swift test "$@"
