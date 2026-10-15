#!/usr/bin/env sh
set -eu

artifact_dir="dist/registry/quaver"
expected_version="$(sed -n 's/^version = "\(.*\)"$/\1/p' moonstone.toml | head -n 1)"
archive="$artifact_dir/quaver-$expected_version-source.tar.gz"

test -n "$expected_version"
moon exec -- ballad play partiture.lua
test -f "$archive"
test -f "$artifact_dir/package.toml"
test -f "$artifact_dir/README.md"
grep -Fqx 'name = "quaver"' "$artifact_dir/package.toml"
grep -Fqx "version = \"$expected_version\"" "$artifact_dir/package.toml"
tar -tzf "$archive" | grep -Fq 'src/quaver.lua'
tar -tzf "$archive" | grep -Fq 'src/quaver/optimizer.lua'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
cp "$archive" "$tmp_dir/first.tar.gz"
first_hash="$(shasum -a 256 "$tmp_dir/first.tar.gz" | awk '{print $1}')"

moon exec -- ballad play partiture.lua
second_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
test "$first_hash" = "$second_hash"

printf 'Reproducible Quaver %s source artifact: %s\n' "$expected_version" "$second_hash"
