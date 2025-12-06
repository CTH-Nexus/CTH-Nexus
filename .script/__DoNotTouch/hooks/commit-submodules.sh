#!/usr/bin/env sh
# .script/__DoNotTouch/hooks/commit-submodules.sh
# 親専用：
#  - 管轄（.gitmodules の PATH/URL に USER_ID（大小無視）を含む）抽出（前段フィルタ＋キャッシュ）
#  - Add+Commit（並列／完了待ち／失敗で親コミット中止）
#  - Commit成功分の gitlink を親で stage（git add -- <path>）
#  - Push（並列／完了待ち／失敗はログのみで親コミット継続）
#
# 改修ポイント：
#  - 呼び出し時引数の GIT_EXE（必須）を常に優先。`.env` の GIT_EXE は存在しても無視。
#  - `.env` は親リポジトリ直下（$ROOT/.env）を絶対パスで読み込む。
#  - PortableGit探索ロジックは削除（pre-commit側で解決済みの想定）。
#  - 環境汚染対策（GIT_DIR/GIT_WORK_TREE/GIT_EXEC_PATH を unset）を維持。

set -eu

# ---------- logging ----------
log() { printf '[commit-submodules] %s\n' "$*" 1>&2; }
err() { printf '[commit-submodules] %s\n' "$*" 1>&2; }

# ---------- 引数（GIT_EXE）受け取り・検証 ----------
if [ $# -lt 1 ]; then
  err "ERROR: GIT_EXE argument is required. Usage: $0 <GIT_EXE>"
  exit 1
fi
GIT_EXE_ARG="$1"

# 存在＆起動検証（-x だけでなく --version 実行で確認）
if [ ! -e "$GIT_EXE_ARG" ]; then
  err "ERROR: GIT_EXE '$GIT_EXE_ARG' not found."
  exit 1
fi
if ! "$GIT_EXE_ARG" --version >/dev/null 2>&1; then
  err "ERROR: GIT_EXE '$GIT_EXE_ARG' is not invokable."
  exit 1
fi

# ローカルで最優先利用する Git 実行ファイル
GIT_EXE="$GIT_EXE_ARG"
log "GIT_EXE (argument-priority) is: $GIT_EXE"

# ---------- 親/子判定 & ルート決定（先にROOTを確定） ----------
SUPER="$($GIT_EXE rev-parse --show-superproject-working-tree 2>/dev/null || true)"
TOP="$($GIT_EXE rev-parse --show-toplevel 2>/dev/null || true)"
ROOT="${SUPER:-$TOP}"
if [ -z "$ROOT" ]; then
  err "ERROR: Unable to resolve repository root (not in a Git worktree?)."
  exit 1
fi
cd "$ROOT"
log "ROOT is $ROOT"

# 子（サブモジュール内）なら親専用オーケストレーションをスキップ
SUPER_OUT="$($GIT_EXE rev-parse --show-superproject-working-tree 2>/dev/null || true)"
if [ -n "$SUPER_OUT" ]; then
  log "In submodule worktree; skip parent-only commit orchestration."
  exit 0
fi

# ---------- .env 読み込み（$ROOT/.env） ----------
# .env に GIT_* が紛れ込んでいても安全にする（このプロセス内のみ）
unset GIT_DIR GIT_WORK_TREE GIT_EXEC_PATH

if [ -f "$ROOT/.env" ]; then
  # 絶対パスで読み込む（位置に依存しない）
  set -a
  while IFS= read -r line || [ -n "$line" ]; do
    # BOM除去（1行目だけでなく全行対応）
    line=$(printf '%s' "$line" | sed 's/^\xEF\xBB\xBF//')

    # 前後の空白除去
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # 空行・コメント行はスキップ
    case "$line" in
      ''|'#'*) continue ;;
    esac

    # インラインコメント削除（値に # を含めたい場合はクォート必須）
    line=$(printf '%s' "$line" | sed -E 's/[[:space:]]+#.*$//')

    # KEY=VALUE のみ export
    case "$line" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        eval "export $line"
        ;;
      *)
        log "WARN: Ignored invalid .env line: $line"
        ;;
    esac
  done < "$ROOT/.env"
  set +a

  # .env に GIT_EXE が存在する場合は無視したことをログ（トラブルシュート向け）
  if [ "${GIT_EXE:-}" != "$GIT_EXE_ARG" ]; then
    log "INFO: .env contains GIT_EXE='${GIT_EXE:-}', but argument-priority overrides to '$GIT_EXE_ARG'."
  fi

  # 引数優先を厳守
  GIT_EXE="$GIT_EXE_ARG"
else
  log "INFO: $ROOT/.env not found; proceed with environment defaults."
fi

# デバッグトレース切替（本番は 0 推奨）
if [ "${DEBUG_TRACE_SETUP:-0}" = "1" ]; then
  export GIT_TRACE_SETUP=1
else
  unset GIT_TRACE_SETUP
fi

# ---------- 設定（固定） ----------
USER_ID="${USER_ID:-}"
SUBMODULE_BRANCH="main"     # 固定
SUBMODULE_COMMIT_MODE="all" # 固定

if [ -z "$USER_ID" ]; then
  err "ERROR: USER_ID is not set in .env. Cannot determine managed submodules."
  exit 1
fi

if [ ! -f ".gitmodules" ]; then
  log "No .gitmodules found. Nothing to do."
  exit 0
fi

# ---------- キャッシュ（高速化） ----------
CACHE_DIR="$ROOT/.cache"
CACHE_FILE="$CACHE_DIR/managed_submodules.${USER_ID}.list"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

GM_MTIME="$(date -r ".gitmodules" +%s 2>/dev/null || stat -c %Y ".gitmodules" 2>/dev/null || echo 0)"

load_cache=0
if [ -f "$CACHE_FILE" ]; then
  cf_mtime="$(awk -F= '/^# *mtime=/{print $2}' "$CACHE_FILE" 2>/dev/null | tail -n1)"
  [ -n "$cf_mtime" ] && [ "$cf_mtime" = "$GM_MTIME" ] && load_cache=1
fi

lc_uid="$(printf "%s" "$USER_ID" | tr '[:upper:]' '[:lower:]')"

managed=""
if [ "$load_cache" -eq 1 ]; then
  log "Use cache: $CACHE_FILE (mtime=$GM_MTIME)"
  managed="$(awk 'NF && $0 !~ /^#/{print $0}' "$CACHE_FILE" 2>/dev/null || true)"
else
  log "Rebuild managed list from .gitmodules (mtime=$GM_MTIME)"

  # 前段フィルタ：PATH と URL を USER_ID 部分一致（大小無視）で絞り込み
  $GIT_EXE --no-pager config -f .gitmodules --get-regexp '^submodule\..*\.path' 2>/dev/null \
    | awk '{sub("submodule\\.","",$1); sub("\\.path","",$1); print $1, $2}' \
    | awk -v uid="$lc_uid" 'BEGIN{IGNORECASE=1} tolower($2) ~ uid {print $1, $2}' > .paths.filtered.tmp || true

  $GIT_EXE --no-pager config -f .gitmodules --get-regexp '^submodule\..*\.url' 2>/dev/null \
    | awk '{sub("submodule\\.","",$1); sub("\\.url","",$1); print $1, $2}' \
    | awk -v uid="$lc_uid" 'BEGIN{IGNORECASE=1} tolower($2) ~ uid {print $1, $2}' > .urls.filtered.tmp || true

  # union→path 正規化
  awk '
    FNR==NR {p[$1]=$2; next}
    {u[$1]=$2}
    END {
      for (n in p) print p[n];
      for (n in u) if (!(n in p)) print n;
    }' .paths.filtered.tmp .urls.filtered.tmp \
    | while read -r key; do
        path="$($GIT_EXE --no-pager config -f .gitmodules --get submodule.$key.path 2>/dev/null || echo "$key")"
        [ -n "$path" ] && printf '%s\n' "$path"
      done \
    | awk 'NF' | sort -u > .managed.rebuild.tmp

  managed="$(cat .managed.rebuild.tmp 2>/dev/null || true)"
  rm -f .paths.filtered.tmp .urls.filtered.tmp .managed.rebuild.tmp

  {
    printf '# mtime=%s ts=%s\n' "$GM_MTIME" "$(date '+%Y-%m-%dT%H:%M:%S')"
    printf '%s\n' "$managed"
  } > "$CACHE_FILE"
fi

log "Managed Submodules are:"
printf '%s\n' "$managed" | sed 's/^/  - /' 1>&2

[ -z "$managed" ] && { log "No managed submodules found for USER_ID='$USER_ID'. Nothing to do."; exit 0; }

# ---------- Add+Commit（並列、変更ありのみ） ----------
tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t commit-submodules)"
success_list="$tmpdir/committed.list"
error_list="$tmpdir/commit_errors.list"
: > "$success_list"; : > "$error_list"

commit_pids=""
for p in $managed; do
  # --- robust submodule worktree check ---
  # 1) .git ポインタの存在
  if [ ! -e "$p/.git" ]; then
    log "WARN: $p is not initialized (.git missing). Skip. Run: git submodule update --init -- \"$p\""
    continue
  fi

  # 2) 絶対 git-dir を取得
  git_dir_abs="$($GIT_EXE -C "$p" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
  if [ -z "$git_dir_abs" ]; then
    git_dir="$($GIT_EXE -C "$p" rev-parse --git-dir 2>/dev/null || echo '')"
    if [ -z "$git_dir" ]; then
      log "WARN: $p rev-parse --git-dir failed. Skip."
      continue
    fi
    case "$git_dir" in
      /*) git_dir_abs="$git_dir" ;;
      [A-Za-z]:/*) git_dir_abs="$git_dir" ;;
      *) git_dir_abs="$p/$git_dir" ;;
    esac
  fi

  # 3) 実体ディレクトリ存在チェック（親 .git/modules/<sub>）
  if [ ! -d "$git_dir_abs" ]; then
    log "WARN: $p git-dir not found: $git_dir_abs. Skip. Run: git submodule update --init -- \"$p\""
    continue
  fi

  # 4) 最終確認：ワークツリー認識
  if ! "$GIT_EXE" -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "WARN: $p is not recognized as a Git worktree. Skip."
    continue
  fi

  # --- サブモジュール専用 Git ラッパ（環境変数前置で強制固定 & フック無効化） ---
  g() {
    GIT_DIR="$git_dir_abs" \
    GIT_COMMON_DIR="$git_dir_abs" \
    GIT_WORK_TREE="$p" \
    GIT_INDEX_FILE="$git_dir_abs/index" \
    "$GIT_EXE" -c core.hooksPath= "$@"
  }

  # デバッグ時のみ表示
  if [ "${DEBUG_TRACE_SETUP:-0}" = "1" ]; then
    log "git-dir is $git_dir_abs / work-tree is $p"
  fi

  # 変更検出（常に全変更対象）
  changes="$(g status --porcelain | wc -l | tr -d ' ')"
  if [ "$changes" -eq 0 ]; then
    log "$p: no changes. Skip commit/push."
    continue
  fi

  (
    current_branch="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    if [ "$current_branch" != "$SUBMODULE_BRANCH" ]; then
      log "WARN: $p on '$current_branch' (expected '$SUBMODULE_BRANCH'); commit proceeds on current branch."
    fi

    g add -A

    msg="pre-commit: update $p ($(date '+%Y-%m-%d %H:%M'))"
    log "$p: commit... msg='$msg'"
    if g commit -m "$msg" --no-verify; then
      printf '%s\n' "$p" >> "$success_list"
      exit 0
    else
      printf '%s\n' "$p" >> "$error_list"
      exit 1
    fi
  ) &
  commit_pids="$commit_pids $!"
done

for pid in $commit_pids; do wait "$pid" || true; done

committed_paths="$(awk 'NF' "$success_list" 2>/dev/null || true)"
failed_commits="$(awk 'NF' "$error_list" 2>/dev/null || true)"

rm -f "$success_list" "$error_list"; rmdir "$tmpdir" 2>/dev/null || true

if [ -n "$failed_commits" ]; then
  err "ERROR: One or more submodule commits failed:"
  printf '%s\n' "$failed_commits" | sed 's/^/  - /' 1>&2
  exit 1
fi

if [ -z "$committed_paths" ]; then
  log "No submodule commits performed. Done."
  exit 0
fi

# ---------- stage gitlink in parent（for commit-success paths only） ----------
for p in $committed_paths; do
  log "$p: stage gitlink in parent."
  $GIT_EXE add -- "$p"
done

# ---------- parallel push（wait; errors logged but parent continues） ----------
push_pids=""
for p in $committed_paths; do
  git_dir_abs="$($GIT_EXE -C "$p" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
  log "$p: push (parallel)..."
  GIT_DIR="$git_dir_abs" GIT_COMMON_DIR="$git_dir_abs" GIT_WORK_TREE="$p" "$GIT_EXE" push origin "$SUBMODULE_BRANCH" &
  push_pids="$push_pids $!"
done

log "Wait for parallel pushes..."
push_errors=0
for pid in $push_pids; do
  if ! wait "$pid"; then push_errors=$((push_errors + 1)); fi
done

if [ "$push_errors" -gt 0 ]; then
  err "ERROR: $push_errors push(es) failed. Parent commit continues, but remote may lack some submodule commits."
fi

exit 0
