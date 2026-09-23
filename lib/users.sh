#!/usr/bin/env bash
# users.sh - VLESS user CRUD. Every mutation regenerates the full Xray
# config and applies it atomically (see config.sh: xray_config_apply).
# shellcheck disable=SC2016  # jq filters are intentionally single-quoted (no bash expansion wanted)

if [[ -n "${VLESS_USERS_SH_LOADED:-}" ]]; then return 0; fi
VLESS_USERS_SH_LOADED=1

user_exists_by_name() {
    local profile_id="$1" name="$2"
    [[ "$(state_query --arg p "$profile_id" --arg n "$name" \
        '[.users[] | select(.profile_id==$p and .name==$n)] | length')" != "0" ]]
}

user_exists_by_id() {
    local uuid="$1"
    [[ "$(state_query --arg id "$uuid" '[.users[] | select(.id==$id)] | length')" != "0" ]]
}

gen_uuid() {
    if [[ -x "$VLESS_XRAY_BIN" ]]; then
        local out; out="$("$VLESS_XRAY_BIN" uuid 2>/dev/null)"
        [[ -n "$out" ]] && { printf '%s' "$out"; return; }
    fi
    if has_cmd uuidgen; then uuidgen; return; fi
    cat /proc/sys/kernel/random/uuid
}

_apply_state_change_or_die() {
    local candidate; candidate="$(mk_tmp_file)"
    xray_full_config_build > "$candidate"
    xray_config_apply "$candidate" || die "the requested change produced an invalid/unhealthy configuration; it has been rolled back"
}

user_add() {
    local profile_id="$1" name="$2"
    profile_exists "$profile_id" || die "no such profile: $profile_id"
    is_valid_username "$name" || die "invalid username: $name"
    user_exists_by_name "$profile_id" "$name" && die "user '$name' already exists on profile '$profile_id'"

    local uuid; uuid="$(gen_uuid)"
    is_valid_uuid "$uuid" || die "failed to generate a valid UUID"

    state_mutate '.users += [{id:$id, name:$name, profile_id:$pid, enabled:true, created_at:$now}]' \
        --arg id "$uuid" --arg name "$name" --arg pid "$profile_id" --arg now "$(now_iso)"

    _apply_state_change_or_die
    log_ok "User '$name' added to profile '$profile_id' (uuid: $uuid)"
}

user_delete() {
    local name="$1" profile_id="${2:-}"
    local hits
    if [[ -n "$profile_id" ]]; then
        hits="$(state_query --arg n "$name" --arg p "$profile_id" '[.users[]|select(.name==$n and .profile_id==$p)]|length')"
    else
        hits="$(state_query --arg n "$name" '[.users[]|select(.name==$n)]|length')"
    fi
    [[ "$hits" != "0" ]] || die "no such user: $name"

    if [[ -n "$profile_id" ]]; then
        state_mutate '.users |= map(select(!(.name==$n and .profile_id==$p)))' --arg n "$name" --arg p "$profile_id"
    else
        state_mutate '.users |= map(select(.name!=$n))' --arg n "$name"
    fi
    _apply_state_change_or_die
    log_ok "User '$name' deleted"
}

user_set_enabled() {
    local name="$1" enabled="$2"
    state_mutate '.users |= map(if .name==$n then .enabled=$e else . end)' \
        --arg n "$name" --argjson e "$enabled"
    _apply_state_change_or_die
}

user_list() {
    state_query -c '.users[] | {name,id,profile_id,enabled,created_at}'
}

user_get_json() {
    local name="$1"
    state_query --arg n "$name" -c '.users[] | select(.name==$n)' | head -1
}
