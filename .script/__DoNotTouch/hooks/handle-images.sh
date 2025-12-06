#!/bin/bash
# handle-images.sh
# 責務: Gitフックのオーケストレーション。設定のロード、対象ファイルの特定、各処理スクリプトの呼び出しを行う。
# Orchestrate: upload-images.sh -> rewrite-mdlink.sh

# --- 定数・初期設定 ---
ENV_FILE=".env"
EXIT_SUCCESS=0
EXIT_FAILURE=1

# --- パス正規化（Windows互換） ---
normalize_windows_path() {
    local p="$1"
    p="${p//\\//}"                                       # \ -> /
    if [[ "$p" =~ ^[A-Za-z]:\/\/ ]]; then                # R:// -> R:/
        p="$(echo "$p" | sed -E 's/^([A-Za-z]):\/+/\1:\//')"
    fi
    p="$(echo "$p" | sed -E 's/\/\/+/\//g' | sed -E 's#^/([A-Za-z]:/)#\1#')"  # //縮約、/C:/補正
    echo "$p"
}

# --- .env ローダ（妥当性検証・上書き禁止キー適用） ---
source_env_file() {
    local env_path="$1"
    [ -z "$env_path" ] || [ ! -f "$env_path" ] && return 0

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        [[ "$line" != *"="* ]] && continue

        key="${line%%=*}"; value="${line#*=}"
        key="$(echo "$key" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        # --- .env からの上書きを禁止するキー ---
        if [[ "$key" == "GIT_EXE" || "$key" == "GIT_CMD" ]]; then
            echo "[ENV] Skip override for protected key: $key"
            continue
        fi

        # 値の整形
        value="$(echo "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        if ! [[ "$value" == \"*\" && "$value" == *\" ]] && ! [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="$(echo "$value" | sed -E 's/[[:space:]]+#.*$//')"
            value="$(echo "$value" | sed -E 's/[[:space:]]+$//')"
        fi
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value#\"}"; value="${value%\"}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value#\'}"; value="${value%\'}"
        fi

        # Windows形式置換 & パス正規化
        value="$(echo "$value" | sed 's/%\([^%]*\)%/$\1/g')"
        value="$(normalize_windows_path "$value")"

        eval "export $key=\"\$value\""
    done < "$env_path"
}

# --- 設定・既定値 ---
load_configuration() {
    export GIT_CMD="${GIT_EXE:-${GIT_CMD:-git}}"
    export DRY_RUN="${DRY_RUN:-false}"
    export LOG_PATH="${LOG_PATH:-uploads.log}"
    export REWRITE_MD="${REWRITE_MD:-true}"

    # リポジトリ直下 .env（保護適用）
    [ -n "$ROOT" ] && [ -f "$ROOT/$ENV_FILE" ] && source_env_file "$ROOT/$ENV_FILE"
}

# --- ユーティリティ ---
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    [ "$DRY_RUN" = "false" ] && echo "$msg" >> "$LOG_PATH"
}
log_error() {
    local msg="[ERROR] $1"
    echo "$msg" >&2
    [ "$DRY_RUN" = "false" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_PATH"
}

# --- Git exe 解析 ---
resolve_git_exe() {
    local git_exe_in="${1:-}"
    if [ -z "$git_exe_in" ]; then
        if [ -n "$USERPROFILE" ] && [ -f "$USERPROFILE/Software/PortableGit/cmd/git.exe" ]; then
            export GIT_EXE="$USERPROFILE/Software/PortableGit/cmd/git.exe"
        elif command -v git >/dev/null 2>&1; then
            export GIT_EXE="$(command -v git)"
        else
            log_error "git.exe not found."; exit $EXIT_FAILURE
        fi
    else
        export GIT_EXE="$git_exe_in"
    fi
    export GIT_CMD="${GIT_EXE:-git}"
    log_message "Using git: $GIT_CMD"
}

# --- ROOT / HOOK_DIR 解決 ---
resolve_repo_root_and_hook_dir() {
    local super top
    is_inside="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    "$GIT_EXE" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    super="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    "$GIT_EXE" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    "$GIT_EXE" rev-parse --show-toplevel 2>/dev/null || true)"
    log_message "is_inside is $is_inside";
    log_message "super is $super";
    log_message "top is $top";
    export SUPER="$super"; export TOP="$top"; export ROOT="${SUPER:-$TOP}"
    [ -z "$ROOT" ] && log_error "Not inside a Git work tree." && exit $EXIT_FAILURE
    export HOOK_DIR="$ROOT/.script/__DoNotTouch/hooks"
    cd "$ROOT" || { log_error "Failed to cd: $ROOT"; exit $EXIT_FAILURE; }
    log_message "ROOT is $ROOT"; log_message "HOOK_DIR is $HOOK_DIR"
}

# --- 親 .env ロード（ROOT -> SUPER） ---
source_parent_env() {
    local candidate
    for candidate in "$ROOT/.env" "$SUPER/.env"; do
        [ -n "$candidate" ] && [ -f "$candidate" ] && { source_env_file "$candidate"; log_message "Sourced .env from $candidate"; break; }
    done
}

# --- index.lock の解放待ち & 安全な git add ---
wait_for_index_unlock() {
    local lock="$ROOT/.git/index.lock"
    local tries=20   # 最大リトライ
    local sleep_s=0.2
    local i
    for ((i=0; i<tries; i++)); do
        [ ! -e "$lock" ] && return 0
        sleep "$sleep_s"
    done
    return 1
}
safe_git_add() {
    local target="$1"
    if wait_for_index_unlock; then
        "$GIT_CMD" add -- "$target"
        return $?
    else
        log_error "Index lock persists; skip staging for: $target"
        return 1
    fi
}

# --- コアロジック ---
get_staged_markdowns() {
    if "$GIT_CMD" rev-parse --verify HEAD >/dev/null 2>&1; then
        "$GIT_CMD" diff-index --cached --name-only --diff-filter=ACMR HEAD | grep -E '\.md$' || true
    else
        "$GIT_CMD" diff --cached --name-only --diff-filter=ACMR | grep -E '\.md$' || true
    fi
}

# 失敗集計（セッション全体で判定に使用）
UPLOAD_FAIL_COUNT=0

process_single_file() {
    local file="$1"
    log_message "Processing: $file"

    # Step 1: 画像アップロード（結果に関わらず Step 2 実行）
    local up_rc=0
    bash "$HOOK_DIR/upload-images.sh" "$file"
    up_rc=$?

    case "$up_rc" in
        0)   log_message "  [Upload] OK for: $file" ;;
        10)  log_message "  [Upload] Skip for: $file" ;;  # 既存/対象なし
        *)   log_error   "  [Upload] FAILED for: $file"; UPLOAD_FAIL_COUNT=$((UPLOAD_FAIL_COUNT+1)) ;;
    esac

    # Step 2: リンク書き換え（常に実行）
    local rw_rc=0
    if [ "$REWRITE_MD" = "true" ]; then
        bash "$HOOK_DIR/rewrite-mdlink.sh" "$file"
        rw_rc=$?

        case "$rw_rc" in
            0)
                log_message "  [Rewrite] OK for: $file"
                # 再ステージング（ドライラン以外、かつ rewrite 成功時のみ）
                if [ "$DRY_RUN" = "false" ]; then
                    if ! safe_git_add "$file"; then
                        log_error "Failed to re-stage. Commit may not include latest rewrite: $file"
                        # 続行（停止はしない）
                    fi
                fi
                ;;
            10)
                log_message "  [Rewrite] Skip for: $file"  # 変化なし/対象なし
                ;;
            *)
                log_error "  [Rewrite] FAILED for: $file"
                # 続行（停止はしない）
                ;;
        esac
    else
        log_message "  [Rewrite] Disabled by setting for: $file"
    fi

    # セッション判定は UPLOAD_FAIL_COUNT にて集計のみ。ここでは戻り値は成功扱いで進める。
    return $EXIT_SUCCESS
}

# --- Main ---
main() {
    resolve_git_exe "${1:-}"
    resolve_repo_root_and_hook_dir
    source_parent_env
    load_configuration

    log_message "=== Session Started: ${USER_ID:-Unknown} ==="
    [ "$DRY_RUN" = "true" ] && echo "!!! DRY RUN MODE: No changes will be made !!!"

    local staged_files; staged_files="$(get_staged_markdowns)"
    if [ -z "$staged_files" ]; then
        log_message "No markdown files staged. Skipping."; exit $EXIT_SUCCESS
    fi

    local IFS=$'\n'
    for file in $staged_files; do
        [ -n "$file" ] && process_single_file "$file"
    done

    log_message "=== Session Completed ==="

    # セッション終了コード決定：
    #   Upload 失敗が一つでもあれば pre-commit 停止（3,4 のみ停止）
    if [ "$UPLOAD_FAIL_COUNT" -gt 0 ]; then
        log_error "Upload failures detected: $UPLOAD_FAIL_COUNT. Aborting commit."
        exit $EXIT_FAILURE
    fi

    exit $EXIT_SUCCESS
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
