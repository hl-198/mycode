#!/bin/bash

# 配置参数
DISK_MOUNT="/"
DISK_THRESHOLD=80
MYSQL_USER="root"
MYSQL_PASSWORD="your_password_here"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
LOG_FILE="/var/log/binlog_cleanup.log"
BINLOG_RETENTION=2
CHECK_INTERVAL=300
MAX_RETRY_ATTEMPTS=3
RETRY_DELAY=5

# 日志函数
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# 警告日志函数
log_warning() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local warning_msg="WARNING: $1"
    echo "[$timestamp] $warning_msg" >> "$LOG_FILE"
    echo "[$timestamp] $warning_msg" >&2
}

# 错误日志函数
log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local error_msg="ERROR: $1"
    echo "[$timestamp] $error_msg" >> "$LOG_FILE"
    echo "[$timestamp] $error_msg" >&2
}

# 验证binlog文件名格式（防止SQL注入）
validate_binlog_name() {
    local binlog_name="$1"
    # 只允许字母、数字和点号
    if [[ ! "$binlog_name" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "非法的binlog文件名格式: $binlog_name"
        return 1
    fi
    return 0
}

# 检查磁盘使用率
check_disk_usage() {
    log "开始检测磁盘使用率..."
    local disk_usage=$(df -h "$DISK_MOUNT" | grep -v Filesystem | awk '{print $5}' | sed 's/%//g')
    log "当前磁盘 $DISK_MOUNT 使用率: ${disk_usage}%"
    echo "$disk_usage"
    return 0
}

# 检查主从同步状态（增强版）
check_replication_status() {
    log "开始检查主从同步状态..."
    local result=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    
    if [ -z "$result" ]; then
        log_error "主从同步状态检查失败 - 无法连接到MySQL数据库，已重试 $MAX_RETRY_ATTEMPTS 次"
        return 1
    fi
    
    # 提取同步状态信息
    local slave_io=$(echo "$result" | grep -i Slave_IO_Running | awk '{print $2}')
    local slave_sql=$(echo "$result" | grep -i Slave_SQL_Running | awk '{print $2}')
    local seconds_behind=$(echo "$result" | grep -i Seconds_Behind_Master | awk '{print $2}')
    local last_errno=$(echo "$result" | grep -i Last_Errno | awk '{print $2}')
    local last_error=$(echo "$result" | grep -i Last_Error | sed 's/Last_Error: //')
    local master_log_file=$(echo "$result" | grep -i Master_Log_File | awk '{print $2}')
    local relay_master_log_file=$(echo "$result" | grep -i Relay_Master_Log_File | awk '{print $2}')
    local read_master_log_pos=$(echo "$result" | grep -i Read_Master_Log_Pos | awk '{print $2}')
    local exec_master_log_pos=$(echo "$result" | grep -i Exec_Master_Log_Pos | awk '{print $2}')
    
    # 记录详细状态信息
    log "Slave_IO_Running: $slave_io"
    log "Slave_SQL_Running: $slave_sql"
    log "Seconds_Behind_Master: $seconds_behind"
    
    if [ "$slave_io" = "Yes" ] && [ "$slave_sql" = "Yes" ] && [ "$seconds_behind" -eq 0 ]; then
        log "主从同步状态正常"
        return 0
    else
        log "主从同步状态不正常，不执行清理操作"
        return 1
    fi
}

# 获取需要保留的binlog文件名
get_binlog_to_keep() {
    log "获取binlog文件列表..."
    local result=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -e "SHOW BINARY LOGS" 2>/dev/null)
    
    if [ -z "$result" ]; then
        log_error "无法获取binlog列表 - MySQL连接失败"
        return 1
    fi
    
    # 使用数组存储binlog列表，避免子shell问题
    local -a binlog_array=()
    local count=0
    
    # 逐行读取binlog列表
    while IFS= read -r line; do
        # 跳过表头
        if [[ "$line" =~ ^Log_name ]]; then
            continue
        fi
        
        # 提取binlog文件名（第一列）
        local binlog_name=$(echo "$line" | awk '{print $1}')
        
        # 验证文件名格式
        if ! validate_binlog_name "$binlog_name"; then
            log_warning "跳过非法的binlog文件: $binlog_name"
            continue
        fi
        
        binlog_array+=("$binlog_name")
        count=$((count + 1))
    done <<< "$result"
    
    log "当前共有 $count 个有效binlog文件"
    
    if [ $count -le $BINLOG_RETENTION ]; then
        log "binlog文件数量 $count 小于等于保留数量 $BINLOG_RETENTION，无需清理"
        echo ""
        return 0
    fi
    
    # 计算需要保留的最旧文件索引
    local keep_start_index=$((count - BINLOG_RETENTION))
    local oldest_to_keep="${binlog_array[$keep_start_index]}"
    
    log "需要保留的最新 $BINLOG_RETENTION 个binlog文件:"
    for ((i=keep_start_index; i<count; i++)); do
        log "  - ${binlog_array[$i]}"
    done
    
    # 再次验证
    if ! validate_binlog_name "$oldest_to_keep"; then
        log_error "需要保留的binlog文件名验证失败: $oldest_to_keep"
        echo ""
        return 1
    fi
    
    echo "$oldest_to_keep"
    return 0
}

# 清除binlog日志（安全版本）
purge_binlog() {
    local oldest_to_keep="$1"
    
    if [ -z "$oldest_to_keep" ]; then
        log "无需清除binlog日志"
        return 0
    fi
    
    # 再次验证文件名（双重验证）
    if ! validate_binlog_name "$oldest_to_keep"; then
        log_error "binlog文件名验证失败，拒绝执行清理操作: $oldest_to_keep"
        return 1
    fi
    
    log "开始清除binlog日志，保留 $oldest_to_keep 及之后的文件..."
    
    # 使用--skip-column-names避免表头干扰
    local result=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -ss -e "PURGE BINARY LOGS TO '$oldest_to_keep';" 2>/dev/null)
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "binlog清除操作成功，已清除 $oldest_to_keep 之前的所有binlog文件"
        return 0
    else
        log_error "binlog清除操作失败，MySQL退出码: $exit_code"
        return 1
    fi
}

# 检查MySQL连接状态
check_mysql_connection() {
    log "检查MySQL连接状态..."
    local result=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -ss -e "SELECT 1" 2>/dev/null)
    
    if [ "$result" = "1" ]; then
        log "MySQL连接正常"
        return 0
    else
        log_error "MySQL连接失败"
        return 1
    fi
}

# 执行单次检查的函数
run_check() {
    log "========================================"
    log "开始新一轮检查周期"
    log "========================================"
    
    # 前置检查：MySQL连接状态
    if ! check_mysql_connection; then
        log_error "MySQL连接失败，跳过本轮检查"
        return 1
    fi
    
    # 检查磁盘使用率
    local disk_usage=$(check_disk_usage)
    
    # 验证磁盘使用率
    if ! [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        log_error "无效的磁盘使用率值: $disk_usage"
        return 1
    fi
    
    if [ "$disk_usage" -lt "$DISK_THRESHOLD" ]; then
        log "磁盘使用率 ${disk_usage}% 未超过阈值 ${DISK_THRESHOLD}%，无需执行清理操作"
        return 0
    fi
    
    log "磁盘使用率 ${disk_usage}% 超过阈值 ${DISK_THRESHOLD}%，继续执行..."
    
    # 检查主从同步状态（如果状态不正常，立即返回，禁止后续操作）
    if ! check_replication_status; then
        log_error "【安全保护】主从同步状态不正常，已禁止执行binlog清理操作"
        log_error "【安全保护】时间戳: $(date '+%Y-%m-%d %H:%M:%S')"
        log_error "【安全保护】异常类型: 主从复制异常"
        log_error "【安全保护】详细描述: Slave_IO_Running或Slave_SQL_Running不为Yes，或存在复制延迟"
        return 1
    fi
    
    # 获取需要保留的binlog文件
    local oldest_to_keep=$(get_binlog_to_keep)
    
    if [ -z "$oldest_to_keep" ]; then
        log "没有需要清除的binlog文件"
        return 0
    fi
    
    # 执行binlog清除操作
    if ! purge_binlog "$oldest_to_keep"; then
        log_error "binlog清除操作失败"
        return 1
    fi
    
    # 再次检查磁盘使用率
    local new_disk_usage=$(df -P "$DISK_MOUNT" | grep -v Filesystem | awk '{print $5}' | sed 's/%//g')
    log "binlog清理完成后，磁盘使用率: ${new_disk_usage}%"
    
    log "========================================"
    log "本轮检查执行完毕"
    log "========================================"
    return 0
}

# 主循环函数
main_loop() {
    log "========================================"
    log "binlog自动清理守护进程已启动"
    log "检查间隔: ${CHECK_INTERVAL}秒"
    log "MySQL主机: ${MYSQL_HOST}:${MYSQL_PORT}"
    log "磁盘监控路径: ${DISK_MOUNT}"
    log "磁盘阈值: ${DISK_THRESHOLD}%"
    log "保留binlog数量: ${BINLOG_RETENTION}"
    log "========================================"
    
    while true; do
        run_check
        
        log "等待 ${CHECK_INTERVAL} 秒后进行下一次检查..."
        sleep "$CHECK_INTERVAL"
    done
}

# 启动主循环
main_loop