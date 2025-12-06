#!/bin/bash
# upload-images.sh
# 責務: Markdown内の画像(wikiリンク/相対パス)のローカル実体を共有フォルダへコピーする
# 戻り値規約: 0=OK(少なくとも1件コピー), 10=Skip(対象なし/既存/ローカル実体なし), 1=Fail(異常)

# --- 共有ユーティリティ（軽量版） ---
normalize_windows_path() {
    local p="$1"
    p="${p//\\//}"
    if [[ "$p" =~ ^[A-Za-z]:\/\/ ]]; then
        p="$(echo "$p" | sed -E 's/^([A-Za-z]):\/+/\1:\//')"
    fi
    p="$(echo "$p" | sed -E 's/\/\/+/\//g' | sed -E 's#^/([A-Za-z]:/)#\1#')"
    echo "$p"
}
log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }

# --- 画像パス絶対化（Vault直下 __Attachment/ 対応） ---
resolve_abs_image_path() {
    local md_file="$1"     # 相対: ROOT基準
    local img_path="$2"    # Markdown記載の画像パス

    # 既に絶対/URIならそのまま
    if [[ "$img_path" =~ ^[A-Za-z]:/ ]] || [[ "$img_path" =~ ^/ ]] || [[ "$img_path" =~ ^file:// ]]; then
        echo "$img_path"; return 0
    fi

    local abs
    if [[ "$img_path" == __Attachment/* ]]; then
        abs="$ROOT/$img_path"                     # Vault直下固定
    else
        local md_dir; md_dir="$(dirname "$md_file")"
        abs="$ROOT/$md_dir/$img_path"             # mdディレクトリ起点
    fi

    if declare -f normalize_windows_path >/dev/null 2>&1; then
        abs="$(normalize_windows_path "$abs")"
    fi
    echo "$abs"
}

# --- 画像コピー（存在チェック＋親ディレクトリ作成） ---
copy_one() {
    local src_rel="$1"   # Markdown上の表記
    local md_file="$2"   # 対象Markdown（相対: ROOT基準）

    # 必須変数
    if [ -z "$UPLOAD_ROOT" ] || [ -z "$USER_ID" ]; then
        log_error "UPLOAD_ROOT or USER_ID is not set."; return 1
    fi

    # 共有ルート正規化（案内用にも使用）
    local upload_root="$UPLOAD_ROOT"
    if declare -f normalize_windows_path >/dev/null 2>&1; then
        upload_root="$(normalize_windows_path "$UPLOAD_ROOT")"
    fi

    # 宛先の「相対パス」を決定（階層保持）
    local dest_rel
    if [[ "$src_rel" == __Attachment/* ]]; then
        dest_rel="$src_rel"                       # __Attachment/... をまるごと保持
    else
        dest_rel="$(basename "$src_rel")"         # それ以外はファイル名のみ（必要なら拡張可）
    fi

    # ローカル実体の絶対化
    local src_abs; src_abs="$(resolve_abs_image_path "$md_file" "$src_rel")"
    local base; base="$(basename "$src_rel")"

    if [ ! -f "$src_abs" ]; then
        # ← Skip として扱い、手動アップロード先を案内（rewrite と同じ階層を指示）
        log_message "  [Upload] Skip: local file missing -> $src_rel (resolved: $src_abs)"
        log_message "           Please upload manually to: \"$upload_root/$USER_ID/$dest_rel\""
        return 10
    fi

    # コピー先（USER_ID サブディレクトリ＋階層）
    local dest_path="$upload_root/$USER_ID/$dest_rel"
    local dest_dir; dest_dir="$(dirname "$dest_path")"

    # 既に存在なら skip（再コピーしない）
    if [ -f "$dest_path" ]; then
        log_message "  [Upload] Skip: already exists -> $dest_path"
        return 10
    fi

    # 親ディレクトリ作成
    if [ ! -d "$dest_dir" ]; then
        if [ "${DRY_RUN:-false}" = "true" ]; then
            log_message "[Upload] DRY-RUN: mkdir -p \"$dest_dir\""
        else
            if mkdir -p "$dest_dir"; then
                log_message "[Upload] Created directory: \"$dest_dir\""
            else
                log_error "[Upload] Failed to create directory: \"$dest_dir\""; return 1
            fi
        fi
    fi

    # コピー
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_message "[Upload] DRY-RUN: cp \"$src_abs\" \"$dest_path\""
        log_message "[Upload] DRY-RUN: rm \"$src_abs\"  # (would delete local source after successful upload)"
        return 0
    else
        if cp -f "$src_abs" "$dest_path"; then
            log_message "[Upload] Copied: \"$src_abs\" -> \"$dest_path\""
            # --- アップロード成功後はローカルファイルを削除 ---
            if rm -f "$src_abs"; then
                log_message "[Upload] Deleted local file: \"$src_abs\""
            else
                # 削除失敗は致命ではないため、警告のみ
                log_error "[Upload] Non-deleted local file: \"$src_abs\""
            fi
            return 0
        else
            log_error "[Upload] Copy failed: \"$src_abs\" -> \"$dest_path\""; return 1
        fi
    fi
}

# --- メイン：対象Markdownの画像リンクを走査しコピー ---
main() {
    local md_file="$1"   # 相対: ROOT基準

    # Markdown本体の絶対パス
    local md_abs="$ROOT/$md_file"
    if [ ! -f "$md_abs" ]; then
        log_error "[Upload] Markdown not found: $md_abs"; return 1
    fi

    local img
    # wikiリンク抽出
    mapfile -t wikilinks < <(grep -oE '!\[\[[^]]+\]\]' "$md_abs" | sed -E 's/^!\[\[//; s/\]\]$//')
    # md画像リンク抽出（角括弧URL含む）
    mapfile -t mdlinks < <(grep -oE '!\[[^]]*\]\((<[^>]+>|[^)]+)\)' "$md_abs" | sed -E 's/^!\[[^]]*\]\(<?([^)>]+)>?\)$/\1/')

    # 結合してユニーク化
    mapfile -t images < <(printf "%s\n" "${wikilinks[@]}" "${mdlinks[@]}" | sed '/^$/d' | sort -u)

    local OK=0 SKIP=0 FAIL=0
    for img in "${images[@]}"; do
        # 角括弧 <...> の除去
        img="${img#<}"; img="${img%>}"
        # URI の場合はローカルコピー不要 → skip
        if [[ "$img" =~ ^file:// ]]; then
            log_message "[Upload] Skip already-URI: $img"
            SKIP=$((SKIP+1))
            continue
        fi

        local rc=0
        copy_one "$img" "$md_file"; rc=$?
        case "$rc" in
            0)  OK=$((OK+1)) ;;
            10) SKIP=$((SKIP+1)) ;;
            *)  FAIL=$((FAIL+1)) ;;
        esac
    done

    if [ "$FAIL" -gt 0 ]; then
        return 1
    elif [ "$OK" -gt 0 ]; then
        return 0
    else
        # 対象なし/既存/ローカル実体なし/すべてURIなど
        return 10
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
