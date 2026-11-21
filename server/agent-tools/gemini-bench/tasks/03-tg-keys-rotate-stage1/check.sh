#!/usr/bin/env bash
# Из корня worktree; общий timeout 120 обеспечивает gemini-bench.
set -euo pipefail
python3 -m py_compile server/tg-gateway/tg_gateway_keys.py server/tg-gateway/test_gateway.py
rotate_help=$(python3 -I server/tg-gateway/tg_gateway_keys.py rotate --help)
printf '%s\n' "$rotate_help"
grep -q -- --json <<< "$rotate_help"
grep -q -- name <<< "$rotate_help"
list_help=$(python3 -I server/tg-gateway/tg_gateway_keys.py list --help)
printf '%s\n' "$list_help"
grep -c -- --json <<< "$list_help"
(cd server/tg-gateway && timeout 120 python3 -m unittest -v \
  test_gateway.GatewayTests.test_key_utility_rotate_replaces_key_and_reloads \
  test_gateway.GatewayTests.test_key_utility_rotate_text_and_errors \
  test_gateway.GatewayTests.test_key_utility_list_json \
  test_gateway.GatewayTests.test_key_utility_add_list_revoke_and_reload \
  test_gateway.GatewayTests.test_key_utility_new_state_show_cert_and_bad_names \
  test_gateway.GatewayTests.test_key_utility_json \
  test_gateway.GatewayTests.test_key_utility_refuses_corrupt_file)
git status --short
