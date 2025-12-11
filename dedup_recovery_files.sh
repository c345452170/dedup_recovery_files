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
# 存放恢复文件模糊哈希索引的路径（可复用以节省重复生成时间）
RECOVERED_HASHES="/tmp/recovered_hashes.txt"

# 删除日志路径
LOG_FILE="./dedup_deleted.log"

# 状态目录与文件，用于缓存比对结果
STATE_DIR="./.dedup_state"
MATCH_RESULTS="$STATE_DIR/hash_matches.txt"
COMPARE_PROGRESS="$STATE_DIR/compare_progress.txt"
DELETE_CANDIDATES="$STATE_DIR/delete_candidates.txt"

# 模拟运行模式（dry run）设置为true不执行删除，只打印操作
DRY_RUN=true

# 相似度判定阈值（百分比）
SIMILARITY_THRESHOLD=90

### === 辅助函数 === ###
function ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

function log_progress() {
  local processed total prefix
  processed="$1"
  total="$2"
  prefix="${3:-进度}"

  local percent
  if [[ "$total" -gt 0 ]]; then
    percent=$((processed * 100 / total))
  else
    percent=0
  fi

  echo "[${prefix}] 已处理: $processed / $total (${percent}%)" >&2
}

### === 核心逻辑 === ###
# 为指定目录生成 ssdeep 哈希索引（如已存在则跳过）
function build_hash_index() {
  local directory="$1"
  local output_file="$2"
  local label="$3"

  if [[ -f "$output_file" ]]; then
    echo "[*] 检测到已有${label}索引，跳过重新生成：$output_file"
    return
  fi

  echo "[*] 正在索引${label}目录：$directory"
  > "$output_file"
  find "$directory" -type f -print0 | while IFS= read -r -d '' file; do
    ssdeep -b "$file" >> "$output_file"
  done
  echo "[*] ${label}索引完成，保存于 $output_file"
}

# 从 ssdeep 输出中提取相似度与匹配路径（兼容 -k 输出，尽量宽松）
function parse_ssdeep_output() {
  local line="$1"
  local score original_path recovered_path

  # 解析相似度：优先提取括号内的数字，其次提取百分数或逗号分隔的首字段
  score=$(echo "$line" | grep -oE '\([0-9]{1,3}\)' | tr -d '()' | tail -n1 || true)
  if [[ -z "$score" ]]; then
    score=$(echo "$line" | grep -oE '[0-9]{1,3}(?=%)' | tail -n1 || true)
  fi
  if [[ -z "$score" ]]; then
    score=$(echo "$line" | awk -F"," '{gsub(/[^0-9]/,"", $1); if($1!="") print $1}' | head -n1)
  fi

  # 抽取左右路径，兼容 "pathA matches pathB (score)" 或 "hash,pathA matches hash,pathB: score" 等格式
  local before after
  before=$(echo "$line" | awk -F"matches" 'NF>1 {print $1}' | sed 's/[[:space:]]*$//')
  after=$(echo "$line" | awk -F"matches" 'NF>1 {print $2}' | sed 's/^[[:space:]]*//')

  if [[ -n "$before" ]]; then
    original_path=$(echo "$before" | awk -F"," '{print $NF}' | sed 's/^ *//;s/ *$//')
  fi

  if [[ -n "$after" ]]; then
    recovered_path=$(echo "$after" | sed -E 's/[[:space:]]*\([0-9]{1,3}\).*//' | awk -F"," '{print $NF}' | sed 's/^ *//;s/ *$//')
  fi

  if [[ -n "$score" && -n "$recovered_path" && -n "$original_path" ]]; then
    echo "$score|$original_path|$recovered_path"
  fi
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

# 通过 hash 列表批量比对，生成删除候选列表
function collect_deletion_candidates() {
  echo "[*] 正在执行批量比对（利用 ssdeep -k，加速处理）..."
  if [[ ! -s "$MATCH_RESULTS" ]]; then
    if ! ssdeep -k "$ORIGINAL_HASHES" "$RECOVERED_HASHES" > "$MATCH_RESULTS" 2>/dev/null; then
      echo "[!] ssdeep -k 执行失败，请确认 ssdeep 版本支持该参数。" >&2
      return 1
    fi
  else
    echo "[*] 检测到已有比对输出，使用缓存结果进行解析。"
  fi

  local total_lines start_line processed_lines
  total_lines=$(wc -l < "$MATCH_RESULTS")
  start_line=1
  processed_lines=0

  if [[ -f "$COMPARE_PROGRESS" ]]; then
    start_line=$(( $(cat "$COMPARE_PROGRESS") + 1 ))
    processed_lines=$((start_line - 1))
    echo "[*] 继续上次进度，从第 $start_line 行开始解析（总计 $total_lines 行）。"
  else
    echo "[*] 开始解析比对结果，总计 $total_lines 行。"
    > "$DELETE_CANDIDATES"
  fi

  tail -n +"$start_line" "$MATCH_RESULTS" | while IFS= read -r line; do
    [[ -z "$line" ]] && { processed_lines=$((processed_lines + 1)); echo "$processed_lines" > "$COMPARE_PROGRESS"; log_progress "$processed_lines" "$total_lines" "比对进度"; continue; }
    local parsed
    parsed=$(parse_ssdeep_output "$line")
    processed_lines=$((processed_lines + 1))
    echo "$processed_lines" > "$COMPARE_PROGRESS"

    [[ -z "$parsed" ]] && { log_progress "$processed_lines" "$total_lines" "比对进度"; continue; }

    local score original_path recovered_path
    score=$(echo "$parsed" | cut -d'|' -f1)
    original_path=$(echo "$parsed" | cut -d'|' -f2)
    recovered_path=$(echo "$parsed" | cut -d'|' -f3-)

    if [[ -n "$score" && $score =~ ^[0-9]+$ && $score -ge $SIMILARITY_THRESHOLD ]]; then
      echo "$recovered_path|原始文件: $original_path 相似度: ${score}%" >> "$DELETE_CANDIDATES"
    fi

    log_progress "$processed_lines" "$total_lines" "比对进度"
  done

  rm -f "$COMPARE_PROGRESS"

  local total_candidates
  total_candidates=$(wc -l < "$DELETE_CANDIDATES")
  echo "[*] 生成删除候选: $total_candidates 条"
}

# 记录删除日志并执行删除（集中处理，避免逐个调用）
function apply_deletions() {
  if [[ ! -s "$DELETE_CANDIDATES" ]]; then
    echo "[*] 未发现需要删除的重复文件"
    return
  fi

  local total processed
  total=$(wc -l < "$DELETE_CANDIDATES")
  processed=0

  while IFS='|' read -r file reason; do
    [[ -z "$file" ]] && continue
    delete_file "$file" "$reason"
    processed=$((processed + 1))
    log_progress "$processed" "$total" "删除进度"
  done < "$DELETE_CANDIDATES"
}

### === 主流程 === ###
trap 'echo "[!] 检测到中断，已记录当前进度。"' SIGINT SIGTERM

ensure_state_dir

echo "=== 恢复数据去重任务开始 ==="
echo "[*] 模式: $( [[ "$DRY_RUN" == true ]] && echo "模拟运行" || echo "真实删除" )"

echo "[*] 删除日志: $LOG_FILE"

echo "[*] 开始准备原始文件索引..."
build_hash_index "$ORIGINAL_DIR" "$ORIGINAL_HASHES" "原始文件"
build_hash_index "$RECOVERED_DIR" "$RECOVERED_HASHES" "恢复文件"

echo "[*] 开始批量比对并生成删除列表..."
if collect_deletion_candidates; then
  echo "[*] 开始集中删除重复项..."
  apply_deletions
else
  echo "[!] 比对失败，未执行删除"
fi

echo "=== 去重完成 ==="
echo "日志路径: $LOG_FILE"
[[ "$DRY_RUN" == true ]] && echo "未执行任何删除，请将 DRY_RUN=false 启用实际删除。"
