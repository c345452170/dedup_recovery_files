#!/bin/bash
# 文件名: dedup_recovery_files.sh
# 作用: 对Photorec恢复的文件与原硬盘文件进行内容相似性比对，自动删除重复项并生成日志

set -e

### === 配置项 === ###
# 原始文件目录（已挂载的硬盘目录）
ORIGINAL_DIR="/mnt/original_disk"

# Photorec恢复出的文件主目录
RECOVERED_DIR="/mnt/recovered_data"

# 存放原始文件模糊哈希索引的路径
ORIGINAL_HASHES="/tmp/original_hashes.txt"

# 删除日志路径
LOG_FILE="./dedup_deleted.log"

# 模拟运行模式（dry run）设置为true不执行删除，只打印操作
DRY_RUN=true

# 相似度判定阈值（百分比）
SIMILARITY_THRESHOLD=90

### === 函数定义 === ###
# 生成原始目录的ssdeep哈希索引
function index_original_files() {
  echo "[*] 正在索引原始文件目录：$ORIGINAL_DIR"
  > "$ORIGINAL_HASHES"
  find "$ORIGINAL_DIR" -type f | while read -r file; do
    ssdeep -b "$file" >> "$ORIGINAL_HASHES"
  done
  echo "[*] 索引完成，保存于 $ORIGINAL_HASHES"
}

# 比对单个恢复文件是否重复
function is_duplicate_file() {
  local file="$1"
  local matches=$(ssdeep -b -m "$ORIGINAL_HASHES" "$file" | tail -n +2)
  if [[ -n "$matches" ]]; then
    local score=$(echo "$matches" | awk -F"," '{print $1}' | tr -d ' ')
    local match_path=$(echo "$matches" | awk -F"," '{print $2}' | sed 's/^[[:space:]]*//')
    if (( score >= SIMILARITY_THRESHOLD )); then
      echo "$score|$match_path"
    fi
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

# 扫描恢复目录进行去重
function scan_recovered_files() {
  echo "[*] 扫描恢复文件目录：$RECOVERED_DIR"
  find "$RECOVERED_DIR" -type f | while read -r recfile; do
    result=$(is_duplicate_file "$recfile")
    if [[ -n "$result" ]]; then
      score=$(echo "$result" | cut -d'|' -f1)
      match_path=$(echo "$result" | cut -d'|' -f2-)
      delete_file "$recfile" "原始文件: $match_path 相似度: ${score}%"
    fi
  done
}

### === 主流程 === ###
echo "=== 恢复数据去重任务开始 ==="
echo "[*] 模式: $( [[ "$DRY_RUN" == true ]] && echo "模拟运行" || echo "真实删除" )"

index_original_files
scan_recovered_files

echo "=== 去重完成 ==="
echo "日志路径: $LOG_FILE"
[[ "$DRY_RUN" == true ]] && echo "未执行任何删除，请将 DRY_RUN=false 启用实际删除。"
