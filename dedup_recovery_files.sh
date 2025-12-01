#!/bin/bash
# 文件名: dedup_recovery_files.sh
# 作用: 对Photorec恢复的文件与原硬盘文件进行内容相似性比对，自动删除重复项并生成日志

set -euo pipefail
IFS=$'\n\t'

### === 配置项 === ###
# 原始文件目录（已挂载的硬盘目录）
ORIGINAL_DIR="/mnt/original_disk"

# Photorec恢复出的文件主目录
RECOVERED_DIR="/mnt/recovered_data"

# 存放原始文件模糊哈希索引的路径
ORIGINAL_HASHES="/tmp/original_hashes.txt"

# 删除日志路径
LOG_FILE="./dedup_deleted.log"

# 状态目录与文件，用于断点续跑
STATE_DIR="./.dedup_state"
RECOVERED_MANIFEST="$STATE_DIR/recovered_manifest.txt"
PROCESSED_LIST="$STATE_DIR/processed_recovered.txt"

# 模拟运行模式（dry run）设置为true不执行删除，只打印操作
DRY_RUN=true

# 相似度判定阈值（百分比）
SIMILARITY_THRESHOLD=90

### === 辅助函数 === ###
function ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  [[ -f "$PROCESSED_LIST" ]] || : > "$PROCESSED_LIST"
}

function load_processed_count() {
  if [[ -f "$PROCESSED_LIST" ]]; then
    wc -l < "$PROCESSED_LIST"
  else
    echo 0
  fi
}

function log_progress() {
  local processed total
  processed="$1"
  total="$2"
  echo "[进度] 已处理: $processed / $total 文件" >&2
}

### === 核心逻辑 === ###
# 生成原始目录的ssdeep哈希索引（如已存在则跳过）
function index_original_files() {
  if [[ -f "$ORIGINAL_HASHES" ]]; then
    echo "[*] 检测到已有索引，跳过重新生成：$ORIGINAL_HASHES"
    return
  fi

  echo "[*] 正在索引原始文件目录：$ORIGINAL_DIR"
  > "$ORIGINAL_HASHES"
  find "$ORIGINAL_DIR" -type f -print0 | while IFS= read -r -d '' file; do
    ssdeep -b "$file" >> "$ORIGINAL_HASHES"
  done
  echo "[*] 索引完成，保存于 $ORIGINAL_HASHES"
}

# 从 ssdeep 输出中提取相似度与匹配路径
function parse_ssdeep_output() {
  local line="$1"
  local score match_path

  # 兼容 "xxx(99)" 或 "99, path" 等多种输出格式
  score=$(echo "$line" | grep -oE '[0-9]{1,3}(?=[)%]*)' | tail -n1 || true)
  if [[ -z "$score" ]]; then
    score=$(echo "$line" | awk -F"," '{gsub(/[^0-9]/,"", $1); if($1!="") print $1}' | head -n1)
  fi

  match_path=$(echo "$line" | awk -F"," 'NF>1 {sub(/^[[:space:]]*/, "", $2); print $2}')
  if [[ -z "$match_path" ]]; then
    match_path=$(echo "$line" | sed -E 's/.*:([^:()]+)\([0-9]{1,3}\).*/\1/' || true)
  fi

  if [[ -n "$score" && -n "$match_path" ]]; then
    echo "$score|$match_path"
  fi
}

# 比对单个恢复文件是否重复
function is_duplicate_file() {
  local file="$1"
  local matches

  if ! matches=$(ssdeep -b -m "$ORIGINAL_HASHES" "$file" 2>/dev/null | tail -n +2); then
    return 1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local parsed
    parsed=$(parse_ssdeep_output "$line")
    if [[ -n "$parsed" ]]; then
      local score match_path
      score=$(echo "$parsed" | cut -d'|' -f1)
      match_path=$(echo "$parsed" | cut -d'|' -f2-)
      if [[ -n "$score" && $score =~ ^[0-9]+$ && $score -ge $SIMILARITY_THRESHOLD ]]; then
        echo "$score|$match_path"
        return 0
      fi
    fi
  done <<< "$matches"

  return 1
}

# 删除重复文件并写日志
function delete_file() {
  local file="$1"
  local reason="$2"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] 将删除: $file 匹配: $reason"
  else
    echo "[$(date "+%F %T")] 删除: $file 匹配: $reason" >> "$LOG_FILE"
    rm -f "$file"
    echo "[+] 已删除: $file"
  fi
}

# 生成/加载恢复文件清单，便于断点续跑
function build_manifest() {
  if [[ -f "$RECOVERED_MANIFEST" ]]; then
    echo "[*] 继续使用已有清单：$RECOVERED_MANIFEST"
    return
  fi

  echo "[*] 正在生成恢复文件清单：$RECOVERED_MANIFEST"
  find "$RECOVERED_DIR" -type f -print0 | sort -z | tr '\0' '\n' > "$RECOVERED_MANIFEST"
}

# 扫描恢复目录进行去重，支持断点续跑
function scan_recovered_files() {
  build_manifest

  local total processed start_line
  total=$(wc -l < "$RECOVERED_MANIFEST")
  processed=$(load_processed_count)
  start_line=$((processed + 1))

  echo "[*] 即将从第 $start_line 行开始处理 (已完成 $processed / $total)"

  tail -n +"$start_line" "$RECOVERED_MANIFEST" | while IFS= read -r recfile; do
    [[ -z "$recfile" ]] && continue
    local result
    result=$(is_duplicate_file "$recfile" || true)
    if [[ -n "$result" ]]; then
      local score match_path
      score=$(echo "$result" | cut -d'|' -f1)
      match_path=$(echo "$result" | cut -d'|' -f2-)
      delete_file "$recfile" "原始文件: $match_path 相似度: ${score}%"
    fi

    # 记录进度，支持续跑
    echo "$recfile" >> "$PROCESSED_LIST"
    processed=$((processed + 1))
    log_progress "$processed" "$total"
  done
}

### === 主流程 === ###
trap 'echo "[!] 检测到中断，已记录当前进度。"' SIGINT SIGTERM

ensure_state_dir

echo "=== 恢复数据去重任务开始 ==="
echo "[*] 模式: $( [[ "$DRY_RUN" == true ]] && echo "模拟运行" || echo "真实删除" )"

echo "[*] 删除日志: $LOG_FILE"

echo "[*] 开始准备原始文件索引..."
index_original_files

echo "[*] 开始扫描去重..."
scan_recovered_files

echo "=== 去重完成 ==="
echo "日志路径: $LOG_FILE"
[[ "$DRY_RUN" == true ]] && echo "未执行任何删除，请将 DRY_RUN=false 启用实际删除。"
