#!/usr/bin/env sh
set -eu

strict_json_sha256() {
  ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$1"
}
