#!/usr/bin/env zsh
# aytool 纯逻辑函数单元测试
# 运行: zsh test_aytool.zsh

source "${0:A:h}/aytool.zsh"

_test_pass=0
_test_fail=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        ((_test_pass++))
        echo "  ${_C_GREEN}✓${_C_RESET} $msg"
    else
        ((_test_fail++))
        echo "  ${_C_RED}✗${_C_RESET} $msg"
        echo "    expected: ${expected}"
        echo "    actual:   ${actual}"
    fi
}

assert_ok() {
    local exit_code=$1 msg="$2"
    if (( exit_code == 0 )); then
        ((_test_pass++))
        echo "  ${_C_GREEN}✓${_C_RESET} $msg"
    else
        ((_test_fail++))
        echo "  ${_C_RED}✗${_C_RESET} $msg (exit: $exit_code)"
    fi
}

assert_fail() {
    local exit_code=$1 msg="$2"
    if (( exit_code != 0 )); then
        ((_test_pass++))
        echo "  ${_C_GREEN}✓${_C_RESET} $msg"
    else
        ((_test_fail++))
        echo "  ${_C_RED}✗${_C_RESET} $msg (expected failure)"
    fi
}

# ── version_gt ──────────────────────────
echo ""
echo "  ${_C_BOLD}version_gt${_C_RESET}"

_aytool_version_gt "3.2.2" "3.2.1"; assert_ok $? "3.2.2 > 3.2.1"
_aytool_version_gt "4.0.0" "3.2.2"; assert_ok $? "4.0.0 > 3.2.2"
_aytool_version_gt "3.2.1" "3.2.2"; assert_fail $? "3.2.1 < 3.2.2"
_aytool_version_gt "3.2.2" "3.2.2"; assert_fail $? "3.2.2 == 3.2.2"
_aytool_version_gt "3.10.0" "3.9.0"; assert_ok $? "3.10.0 > 3.9.0"
_aytool_version_gt "1.0.0" "0.9.9"; assert_ok $? "1.0.0 > 0.9.9"

# ── parse_project ──────────────────────
echo ""
echo "  ${_C_BOLD}parse_project${_C_RESET}"

_aytool_parse_project "tc_go|GO_VER|myimage|~/projects/go||"
assert_eq "tc_go" "$_P_ALIAS" "alias parsed"
assert_eq "GO_VER" "$_P_ENV_VAR" "env_var parsed"
assert_eq "myimage" "$_P_IMAGE" "image parsed"
assert_eq "${HOME}/projects/go" "$_P_BUILD_DIR" "build_dir ~ expanded"
assert_eq "" "$_P_DOCKERFILE" "dockerfile empty"
assert_eq "" "$_P_BUILD_CONTEXTS" "contexts empty"

_aytool_parse_project "tc_sys|SYS_VER|sysimg|~/app|custom/Dockerfile|shared=~/libs"
assert_eq "tc_sys" "$_P_ALIAS" "alias with all fields"
assert_eq "custom/Dockerfile" "$_P_DOCKERFILE" "dockerfile path"
assert_eq "shared=~/libs" "$_P_BUILD_CONTEXTS" "build contexts"

# ── serialize_project ───────────────────
echo ""
echo "  ${_C_BOLD}serialize_project${_C_RESET}"

_P_ALIAS="test"; _P_ENV_VAR="TEST_VER"; _P_IMAGE="img"
_P_BUILD_DIR="${HOME}/mydir"; _P_DOCKERFILE=""; _P_BUILD_CONTEXTS=""
local result=$(_aytool_serialize_project)
assert_eq "test|TEST_VER|img|~/mydir||" "$result" "serialize basic"

_P_BUILD_DIR="${HOME}/app"; _P_DOCKERFILE="sub/Dockerfile"; _P_BUILD_CONTEXTS="ctx=~/lib"
result=$(_aytool_serialize_project)
assert_eq "test|TEST_VER|img|~/app|sub/Dockerfile|ctx=~/lib" "$result" "serialize full"

# roundtrip: parse → serialize → parse
local original="myapp|APP_VER|myimg|~/code|special/Dockerfile|lib=~/shared"
_aytool_parse_project "$original"
local serialized=$(_aytool_serialize_project)
assert_eq "$original" "$serialized" "parse → serialize roundtrip"

# ── read_version / update_version ──────
echo ""
echo "  ${_C_BOLD}read/update_version${_C_RESET}"

local tmp_env=$(mktemp)
echo "FOO_VERSION=5" > "$tmp_env"
echo "BAR_VERSION=10" >> "$tmp_env"
ENV_FILE="$tmp_env"

local v=$(_aytool_read_version "FOO_VERSION")
assert_eq "5" "$v" "read existing version"

v=$(_aytool_read_version "NOT_EXIST")
assert_eq "0" "$v" "read non-existent returns 0"

_aytool_update_version "FOO_VERSION" "6"
v=$(_aytool_read_version "FOO_VERSION")
assert_eq "6" "$v" "update existing version"

_aytool_update_version "NEW_VAR" "1"
v=$(_aytool_read_version "NEW_VAR")
assert_eq "1" "$v" "append new variable"

# BAR_VERSION should be untouched
v=$(_aytool_read_version "BAR_VERSION")
assert_eq "10" "$v" "other vars untouched"

rm -f "$tmp_env"

# ── save/load projects ─────────────────
echo ""
echo "  ${_C_BOLD}save/load_projects${_C_RESET}"

local tmp_proj=$(mktemp)
_AYTOOL_PROJECTS="$tmp_proj"

_PROJECTS=("a|A_VER|img_a|~/dir_a||" "b|B_VER|img_b|~/dir_b||ctx=~/x")
_aytool_save_projects

_PROJECTS=()
_aytool_load_projects
assert_eq "2" "${#_PROJECTS[@]}" "loaded 2 projects"
assert_eq "a|A_VER|img_a|~/dir_a||" "${_PROJECTS[1]}" "first project intact"
assert_eq "b|B_VER|img_b|~/dir_b||ctx=~/x" "${_PROJECTS[2]}" "second project intact"

rm -f "$tmp_proj"

# ── Summary ────────────────────────────
echo ""
echo "  ${_C_DIM}─────────────────────────${_C_RESET}"
echo "  ${_C_GREEN}pass: ${_test_pass}${_C_RESET}  ${_C_RED}fail: ${_test_fail}${_C_RESET}"
echo ""

(( _test_fail > 0 )) && exit 1
exit 0
