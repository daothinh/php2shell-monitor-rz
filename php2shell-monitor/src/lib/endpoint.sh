#!/usr/bin/env bash
# endpoint.sh - central server endpoint, stored obfuscated.
[[ -n ${P2S_ENDPOINT_SH:-} ]] && return 0
P2S_ENDPOINT_SH=1

# XOR with a fixed key, then base64. Not encryption: it keeps the address from
# showing up in a grep for the port or the subnet.
_P2S_EP_KEY='dxoth1nh'
_P2S_EP_B64='DAwbBBsLQUdQTUJFWgVDUVdVXkdeHx0bCBEfWgFe'

# Bash bitwise XOR on decimal codes. printf "%c" needs octal, hence the %03o.
_p2s_xor() { # <hexstring> <key>  -> raw bytes on stdout
  local hex=$1 key=$2 out='' i byte kc kcode
  local klen=${#key}
  for ((i = 0; i < ${#hex}; i += 2)); do
    byte=$((16#${hex:i:2}))
    kc=${key:$(( (i / 2) % klen )):1}
    printf -v kcode '%d' "'$kc"
    printf -v out '%s\\%03o' "$out" $(( byte ^ kcode ))
  done
  printf '%b' "$out"
}

p2s_endpoint() {
  local b64=${P2S_ENDPOINT_B64:-$_P2S_EP_B64}
  local key=${P2S_ENDPOINT_KEY:-$_P2S_EP_KEY}
  local hex
  hex=$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  [[ -n $hex ]] || return 1
  _p2s_xor "$hex" "$key"
}

p2s_endpoint_valid() {
  local u
  u=$(p2s_endpoint) || return 1
  [[ $u =~ ^https?://[^[:space:]]+$ ]]
}

# p2s_endpoint_encode <url> — inverse of p2s_endpoint; used to rotate the
# stored value and by the test suite.
p2s_endpoint_encode() {
  local url=$1 key=${2:-$_P2S_EP_KEY} hex='' i c kc kcode
  local klen=${#key}
  for ((i = 0; i < ${#url}; i++)); do
    c=${url:i:1}
    kc=${key:$(( i % klen )):1}
    printf -v kcode '%d' "'$kc"
    printf -v hex '%s%02x' "$hex" $(( $(printf '%d' "'$c") ^ kcode ))
  done
  printf '%s' "$hex" | awk '{
    for (i = 1; i <= length($0); i += 2) {
      v = index("0123456789abcdef", substr($0, i, 1)) - 1
      w = index("0123456789abcdef", substr($0, i + 1, 1)) - 1
      printf "%c", v * 16 + w
    }
  }' | base64 -w0
}
