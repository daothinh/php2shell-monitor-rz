# test_helper.bash - bats helpers
SRC=${SRC:-/tmp/php2shell-monitor}
FIX=$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)

assert_field() { # <tsv-line> <n> <expected>
  local line=$1 n=$2 expected=$3
  local got
  got=$(printf '%s' "$line" | awk -F'\t' -v n="$n" 'NR==1 { print $n }')
  [[ $got == "$expected" ]]
}

# mkstream: fresh empty stream file with a temp workdir configured
mkstream() {
  local f
  f=$(mktemp)
  printf '%s' "$f"
}

# rule_match_stream: run rule_match.sh against a stream file in an isolated workdir
rule_match_stream() {
  local stream=$1
  local w
  w=$(mktemp -d)
  # minimal engine layout for the matcher
  mkdir -p "$w/rules/pack" "$w/conf" "$w/state"
  cp -a "$SRC/rules/pack/." "$w/rules/pack/" 2>/dev/null
  WORKDIR=$w P2S_SRC_DIR=$w bash "$SRC/engine/rule_match.sh" "$stream" 2>/dev/null
  rm -rf -- "$w"
}
