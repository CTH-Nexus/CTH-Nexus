#!/bin/bash
# rewrite-mdlink.sh
# 責務: Markdown内のWikiLink(![[...]])を、共有フォルダを指す標準リンク(![alt](<file://...>))に置換する。

# --- 定数・初期設定 ---
EXIT_SUCCESS=0
EXIT_FAILURE=1

# デフォルト設定
UPLOAD_ROOT="${UPLOAD_ROOT:-R:\\Upload}"
USER_ID="${USER_ID:-UNKNOWN}"
IMAGE_EXTS="${IMAGE_EXTS:-.png,.jpg,.jpeg,.gif,.bmp,.tif,.tiff,.webp}"
DRY_RUN="${DRY_RUN:-false}"
LOG_PATH="${LOG_PATH:-uploads.log}"

# --- 1. ユーティリティ関数 ---
log_msg() {
    local msg="  [Rewrite] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]$msg"
    if [ "$DRY_RUN" = "false" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_PATH"
    fi
}

# --- 2. 個別ロジック関数 ---

# 新しいMarkdownリンク文字列を生成する
generate_new_link() {
    local filename="$1"

    # Alt text生成
    local basename_val=$(basename "$filename")
    local alt_text="${basename_val%.*}"

    # --- パスの正規化ロジック (ここを修正) ---

    # 1. 入力された UPLOAD_ROOT をクリーンにする
    #    sed 1回目: バックスラッシュ(\) を スラッシュ(/) に全置換
    #    sed 2回目: 重複するスラッシュ(//) を 単一スラッシュ(/) に置換
    #    これにより 'R:\\Upload' -> 'R://Upload' -> 'R:/Upload' に補正されます。
    local clean_root=$(echo "$UPLOAD_ROOT" | sed 's/\\/\//g' | sed 's|//|/|g')

    # 2. Git Bashパス (/r/Upload) -> Windowsパス (R:/Upload) への変換
    #    既に Windows形式 (R:/Upload) になっている場合はマッチしないのでそのまま通ります
    local win_path_root=$(echo "$clean_root" | sed 's|^/\([a-z]\)/|\U\1:/|')

    # 3. URL生成
    #    win_path_root は既に綺麗な状態なので、そのまま結合します
    local new_url="file:///${win_path_root}/${USER_ID}/${filename}"

    # 結果を出力
    echo "![${alt_text}](<${new_url}>)"
}

# sedによる置換を実行
perform_sed_replacement() {
    local target_file="$1"
    local old_link_str="$2"
    local new_link_str="$3"

    # sed用に特殊文字をエスケープ
    # Link内の [ ] | をバックスラッシュでエスケープする
    local search_pattern
    search_pattern=$(echo "$old_link_str" | sed 's/\[/\\[/g; s/\]/\\]/g; s/|/\\|/g')

    if [ "$DRY_RUN" = "true" ]; then
        log_msg "(DRY-RUN) Would replace: $old_link_str -> $new_link_str"
    else
        # ファイル直接書き換え
        sed -i "s|$search_pattern|$new_link_str|g" "$target_file"
        log_msg "Replaced: $old_link_str -> $new_link_str"
    fi
}

# 1つのリンクに対する書き換え処理
process_link_rewrite() {
    local match_str="$1"
    local target_file="$2"

    # 文字列解析
    local content="${match_str#!\[\[}"
    content="${content%\]\]}"
    local filename="${content%%|*}"

    # 拡張子チェック (画像以外は書き換えない設定の場合)
    local file_ext=".${filename##*.}"
    if [[ ",$IMAGE_EXTS," != *",$file_ext,"* ]]; then
        return $EXIT_SUCCESS
    fi

    # 新しいリンクを生成
    local new_link
    new_link=$(generate_new_link "$filename")

    # 置換実行
    perform_sed_replacement "$target_file" "$match_str" "$new_link"
}

# --- 3. Main関数 ---
main() {
    local target_file="$1"

    if [ ! -f "$target_file" ]; then
        exit $EXIT_FAILURE
    fi

    # 重複を除去してループ (同じ画像を複数箇所で使っている場合の効率化)
    grep -o '!\[\[[^]]*\]\]' "$target_file" | sort -u | while read -r match; do
        if [ -n "$match" ]; then
            process_link_rewrite "$match" "$target_file"
        fi
    done

    exit $EXIT_SUCCESS
}

# スクリプトとして実行した時は main が走り、
# 他のファイルから読み込んだ時は関数定義だけされる
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
