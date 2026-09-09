#!/bin/bash

set -e

rustup target add aarch64-linux-android
cargo install cargo-ndk
cargo ndk build --release --target=aarch64-linux-android

# uniffi bindings
cargo run --bin uniffi-bindgen generate \
  --library ./target/aarch64-linux-android/release/libmanna_core.a \
  --language kotlin \
  --out-dir ./Bindings
cp -r ./Bindings/ ../../../android/app/src/main/kotlin