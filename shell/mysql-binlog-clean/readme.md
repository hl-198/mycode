# MySQL Binlog 自动清理脚本

## 一、脚本运行逻辑

### 1.1 整体架构

脚本采用**守护进程模式**运行，启动后进入无限循环，按固定间隔周期性执行检查与清理操作。核心流程如下：

```
启动脚本
  │
  ▼
main_loop() ─── 进入无限循环
  │
  ▼
run_check() ─── 执行单次检查周期
  │
  ├── 1. check_mysql_connection()  ── MySQL连接检查
  │
  ├── 2. check_disk_usage()        ── 磁盘使用率检测
  │
  ├── 3. check_replication_status() ── 主从同步状态检查
  │
  ├── 4. get_binlog_to_keep()      ── 计算需保留的binlog文件
  │
  ├── 5. purge_binlog()            ── 执行binlog清理
  │
  └── 6. 清理后磁盘使用率确认
  │
  ▼
sleep CHECK_INTERVAL ── 等待下一轮检查
  │
  ▼
返回循环顶部，重复执行
```

### 1.2 功能模块详解

#### 模块一：日志系统

| 函数 | 输出目标 | 用途 |
|------|---------|------|
| `log()` | 仅写入日志文件 | 记录常规操作信息 |
| `log_warning()` | 日志文件 + 标准错误输出 | 记录警告信息 |
| `log_error()` | 日志文件 + 标准错误输出 | 记录错误信息 |

所有日志条目均包含时间戳，格式为 `[YYYY-MM-DD HH:MM:SS]`。

#### 模块二：安全验证 — `validate_binlog_name()`

在执行 `PURGE BINARY LOGS TO` 语句前，对binlog文件名进行格式校验，仅允许字母、数字、点和连字符，防止SQL注入攻击。该函数在以下位置被调用：

- `get_binlog_to_keep()` 中解析binlog列表时（逐个校验）
- `get_binlog_to_keep()` 返回结果前（再次校验）
- `purge_binlog()` 执行清理前（双重校验）

#### 模块三：MySQL连接检查 — `check_mysql_connection()`

执行 `SELECT 1` 验证数据库连接是否可用。若连接失败，跳过本轮所有后续操作，等待下一轮重试。

#### 模块四：磁盘使用率检测 — `check_disk_usage()`

通过 `df -h` 命令获取指定挂载点的磁盘使用率，去除百分号后返回整数值。检测到的使用率会与 `DISK_THRESHOLD` 阈值比较：

- **低于阈值**：记录日志，本轮不执行清理
- **达到或超过阈值**：继续执行后续主从状态检查

#### 模块五：主从同步状态检查 — `check_replication_status()`

执行 `SHOW SLAVE STATUS\G` 获取从库复制状态，提取并记录以下关键指标：

| 指标 | 含义 | 正常值 |
|------|------|--------|
| `Slave_IO_Running` | IO线程是否运行 | Yes |
| `Slave_SQL_Running` | SQL线程是否运行 | Yes |
| `Seconds_Behind_Master` | 从库延迟秒数 | 0 |

**判断逻辑**：三个指标全部满足条件时，才认为主从同步正常，允许执行后续清理操作。任一条件不满足，立即终止本轮操作并记录安全保护日志。

#### 模块六：Binlog文件计算 — `get_binlog_to_keep()`

执行 `SHOW BINARY LOGS` 获取当前所有binlog文件列表，处理流程：

1. 逐行解析输出，跳过表头行
2. 对每个文件名调用 `validate_binlog_name()` 校验格式
3. 将合法文件名存入Bash数组
4. 若文件总数 ≤ `BINLOG_RETENTION`，无需清理，返回空值
5. 否则计算保留起点：`保留起点索引 = 文件总数 - BINLOG_RETENTION`
6. 返回保留起点对应的binlog文件名

**示例**（`BINLOG_RETENTION=2`）：

```
当前binlog文件：
  mysql-bin.037470  ─┐
  mysql-bin.037471   │ 将被清除
  mysql-bin.037472  ─┘
  mysql-bin.037473  ─┐ 保留
  mysql-bin.037474  ─┘ 保留

返回值：mysql-bin.037473（保留此文件及之后的文件）
```

#### 模块七：Binlog清理执行 — `purge_binlog()`

执行 `PURGE BINARY LOGS TO '<文件名>'`，清除指定文件之前的所有binlog。执行前进行双重安全验证：

1. 空值检查：目标文件名为空则跳过
2. 格式验证：再次调用 `validate_binlog_name()` 校验

执行后检查MySQL命令退出码，记录操作结果。

#### 模块八：主循环 — `main_loop()`

启动时记录守护进程配置信息，然后进入 `while true` 无限循环，每轮执行 `run_check()` 后等待 `CHECK_INTERVAL` 秒。

### 1.3 执行顺序与中断机制

```
check_mysql_connection()  ──失败──→ 跳过本轮，等待下轮
        │成功
        ▼
check_disk_usage()        ──未达阈值──→ 跳过清理，等待下轮
        │达到阈值
        ▼
check_replication_status() ──异常──→ 【安全保护】终止操作，等待下轮
        │正常
        ▼
get_binlog_to_keep()      ──无需清理──→ 等待下轮
        │有文件需清理
        ▼
purge_binlog()            ──失败──→ 记录错误，等待下轮
        │成功
        ▼
记录清理后磁盘使用率
```

---

## 二、脚本使用方式

### 2.1 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | CentOS 7 / CentOS 8 或兼容的Linux发行版 |
| MySQL版本 | MySQL 5.7（主库角色） |
| MySQL客户端 | 系统需安装 `mysql` 命令行客户端 |
| Bash版本 | Bash 4.0+（需要支持 `local -a` 数组声明和 `<<<` Here String） |
| 用户权限 | 需要 root 或具有 `PURGE BINARY LOGS` 权限的MySQL账户 |
| 文件权限 | 对日志文件路径有写入权限 |

### 2.2 配置参数说明

编辑脚本顶部的配置参数区域：

```bash
DISK_MOUNT="/"                # 监控的磁盘挂载点
DISK_THRESHOLD=80             # 磁盘使用率阈值（%），超过此值触发清理
MYSQL_USER="root"             # MySQL登录用户名
MYSQL_PASSWORD="your_password_here"  # MySQL登录密码（必改项）
MYSQL_HOST="localhost"        # MySQL主机地址
MYSQL_PORT="3306"             # MySQL端口号
LOG_FILE="/var/log/binlog_cleanup.log"  # 日志文件路径
BINLOG_RETENTION=2            # 保留的最新binlog文件数量
CHECK_INTERVAL=300            # 检查间隔（秒），默认5分钟
MAX_RETRY_ATTEMPTS=3          # 最大重试次数
RETRY_DELAY=5                 # 重试间隔（秒）
```

### 2.3 基本使用步骤

**第一步：修改配置**

```bash
# 修改MySQL密码（必须）
sed -i 's/your_password_here/实际密码/' clean_binlog.sh

# 如需修改其他参数，直接编辑脚本顶部配置区域
```

**第二步：赋予执行权限**

```bash
chmod +x clean_binlog.sh
```

**第三步：运行脚本**

```bash
# 前台运行（适合调试，Ctrl+C停止）
./clean_binlog.sh

# 后台运行（生产环境推荐）
nohup ./clean_binlog.sh > /dev/null 2>&1 &

# 后台运行并记录进程ID
nohup ./clean_binlog.sh > /dev/null 2>&1 &
echo $! > /var/run/binlog_cleanup.pid
```

**第四步：停止脚本**

```bash
# 方式一：通过进程ID停止
kill $(cat /var/run/binlog_cleanup.pid)

# 方式二：通过进程名查找并停止
ps aux | grep clean_binlog.sh
kill <PID>

# 方式三：如果在前台运行
# 按 Ctrl+C
```

### 2.4 不同场景下的使用示例

#### 场景一：监控数据盘而非根分区

```bash
# 修改配置
DISK_MOUNT="/data"            # 改为数据盘挂载点
DISK_THRESHOLD=85             # 数据盘可适当提高阈值
```

#### 场景二：远程MySQL实例

```bash
# 修改配置
MYSQL_HOST="192.168.1.100"    # 远程MySQL地址
MYSQL_PORT="3307"             # 非默认端口
MYSQL_USER="binlog_admin"     # 使用专用账户
```

#### 场景三：保留更多binlog文件

```bash
# 修改配置
BINLOG_RETENTION=5            # 保留最新5个binlog文件
```

#### 场景四：更频繁的检查

```bash
# 修改配置
CHECK_INTERVAL=60             # 每分钟检查一次
```

### 2.5 预期输出

#### 日志文件输出示例

```
[2026-04-30 10:00:00] ========================================
[2026-04-30 10:00:00] binlog自动清理守护进程已启动
[2026-04-30 10:00:00] 检查间隔: 300秒
[2026-04-30 10:00:00] MySQL主机: localhost:3306
[2026-04-30 10:00:00] 磁盘监控路径: /
[2026-04-30 10:00:00] 磁盘阈值: 80%
[2026-04-30 10:00:00] 保留binlog数量: 2
[2026-04-30 10:00:00] ========================================
[2026-04-30 10:00:00] ========================================
[2026-04-30 10:00:00] 开始新一轮检查周期
[2026-04-30 10:00:00] ========================================
[2026-04-30 10:00:00] 检查MySQL连接状态...
[2026-04-30 10:00:00] MySQL连接正常
[2026-04-30 10:00:00] 开始检测磁盘使用率...
[2026-04-30 10:00:00] 当前磁盘 / 使用率: 85%
[2026-04-30 10:00:00] 磁盘使用率 85% 超过阈值 80%，继续执行...
[2026-04-30 10:00:00] 开始检查主从同步状态...
[2026-04-30 10:00:00] Slave_IO_Running: Yes
[2026-04-30 10:00:00] Slave_SQL_Running: Yes
[2026-04-30 10:00:00] Seconds_Behind_Master: 0
[2026-04-30 10:00:00] 主从同步状态正常
[2026-04-30 10:00:00] 获取binlog文件列表...
[2026-04-30 10:00:00] 当前共有 10 个有效binlog文件
[2026-04-30 10:00:00] 需要保留的最新 2 个binlog文件:
[2026-04-30 10:00:00]   - mysql-bin.037477
[2026-04-30 10:00:00]   - mysql-bin.037478
[2026-04-30 10:00:00] 开始清除binlog日志，保留 mysql-bin.037477 及之后的文件...
[2026-04-30 10:00:01] binlog清除操作成功，已清除 mysql-bin.037477 之前的所有binlog文件
[2026-04-30 10:00:01] binlog清理完成后，磁盘使用率: 62%
[2026-04-30 10:00:01] ========================================
[2026-04-30 10:00:01] 本轮检查执行完毕
[2026-04-30 10:00:01] ========================================
[2026-04-30 10:00:01] 等待 300 秒后进行下一次检查...
```

#### 主从同步异常时的日志示例

```
[2026-04-30 10:05:00] 开始检查主从同步状态...
[2026-04-30 10:05:00] Slave_IO_Running: Yes
[2026-04-30 10:05:00] Slave_SQL_Running: No
[2026-04-30 10:05:00] Seconds_Behind_Master: NULL
[2026-04-30 10:05:00] 主从同步状态不正常，不执行清理操作
[2026-04-30 10:05:00] ERROR: 【安全保护】主从同步状态不正常，已禁止执行binlog清理操作
[2026-04-30 10:05:00] ERROR: 【安全保护】时间戳: 2026-04-30 10:05:00
[2026-04-30 10:05:00] ERROR: 【安全保护】异常类型: 主从复制异常
[2026-04-30 10:05:00] ERROR: 【安全保护】详细描述: Slave_IO_Running或Slave_SQL_Running不为Yes，或存在复制延迟
```

---

## 三、脚本注意事项

### 3.1 安全考量

| 风险项 | 说明 | 建议 |
|--------|------|------|
| **密码明文存储** | MySQL密码以明文写在脚本中，任何有文件读权限的用户均可获取 | 使用MySQL配置文件（`~/.my.cnf`）存储凭据，并将文件权限设为 `chmod 600` |
| **SQL注入防护** | 脚本已实现binlog文件名格式校验（仅允许字母、数字、点和连字符） | 保持现有校验机制，不要移除 `validate_binlog_name()` 调用 |
| **PURGE操作不可逆** | 被清除的binlog文件无法恢复 | 执行前确认从库同步状态正常，建议首次运行前手动备份binlog |

### 3.2 潜在风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| **从库正在读取即将被删除的binlog** | 从库IO线程断开，数据无法追平，需重建从库 | 确保保留的binlog数量（`BINLOG_RETENTION`）足够覆盖从库的读取延迟窗口 |
| **PURGE操作持有锁** | 短暂阻塞其他DDL操作 | 在业务低峰期运行，或适当增大 `CHECK_INTERVAL` |
| **Seconds_Behind_Master为NULL** | 当IO线程未运行时，该值为NULL，整数比较会报错 | 脚本当前使用 `-eq` 比较，NULL值会导致判断异常，建议改用字符串比较 |
| **多实例同时运行** | 多个脚本实例并发执行PURGE可能产生竞态条件 | 使用PID文件锁确保单实例运行 |
| **日志文件无限增长** | 守护进程长期运行后日志文件可能占用大量磁盘 | 定期轮转日志文件，或添加日志大小检查逻辑 |

### 3.3 适用范围限制

- **仅适用于MySQL主库**：脚本在主库上执行 `SHOW SLAVE STATUS` 检查本机作为从库的同步状态，若本机为纯主库（无从库配置），`SHOW SLAVE STATUS` 将返回空结果，脚本会因"无法连接"而跳过清理
- **仅适用于MySQL 5.7**：`SHOW SLAVE STATUS` 和 `PURGE BINARY LOGS TO` 语法在MySQL 5.7上验证通过，其他版本需确认兼容性
- **单从库场景**：脚本仅检查本机的从库状态，若主库下挂多个从库，未检查的从库可能仍在读取旧binlog
- **不支持MariaDB**：MariaDB的复制状态字段名称可能不同

### 3.4 数据备份建议

1. **首次运行前**：手动执行 `SHOW BINARY LOGS` 记录当前binlog文件清单，并使用 `mysqldump` 或物理备份工具做一次全量备份
2. **保留数量设置**：`BINLOG_RETENTION` 建议不低于2，生产环境建议设为3-5，为从库提供足够的缓冲
3. **binlog归档**：如需长期保留binlog用于数据恢复，可在PURGE前将binlog文件复制到归档存储
4. **定期验证**：定期检查从库同步状态，确认 `Master_Log_File` 始终在保留的binlog范围内

### 3.5 权限要求

**MySQL权限**：

```sql
-- 脚本所需的最低权限
GRANT REPLICATION CLIENT ON *.* TO 'binlog_admin'@'localhost';
GRANT SUPER ON *.* TO 'binlog_admin'@'localhost';
```

| 操作 | 所需权限 |
|------|---------|
| `SHOW SLAVE STATUS` | REPLICATION CLIENT 或 SUPER |
| `SHOW BINARY LOGS` | REPLICATION CLIENT |
| `PURGE BINARY LOGS TO` | SUPER |
| `SELECT 1` | 任意数据库的SELECT权限 |

**操作系统权限**：

| 操作 | 所需权限 |
|------|---------|
| 执行 `df` 命令 | 普通用户即可 |
| 写入日志文件 | 对 `/var/log/` 目录有写入权限（通常需要root） |
| 执行 `mysql` 客户端 | 普通用户即可 |
| 后台运行（nohup） | 普通用户即可 |

### 3.6 异常处理方式

| 异常场景 | 脚本行为 | 建议处理 |
|----------|---------|----------|
| MySQL连接失败 | 记录错误日志，跳过本轮检查，等待下轮重试 | 检查MySQL服务状态、网络连通性、账户密码 |
| 磁盘使用率获取异常 | 记录错误日志，跳过本轮检查 | 检查 `DISK_MOUNT` 挂载点是否正确 |
| 主从同步异常 | 记录安全保护日志，禁止执行清理 | 排查从库复制错误，修复后脚本自动恢复 |
| binlog文件名格式异常 | 跳过该文件，记录警告 | 检查是否存在非标准命名的binlog文件 |
| PURGE操作失败 | 记录错误日志和MySQL退出码 | 检查MySQL错误日志，确认是否有锁冲突或权限问题 |
| 脚本进程被意外终止 | 循环中断，不再执行检查 | 建议使用supervisor或systemd管理进程，实现自动重启 |

### 3.7 推荐的进程管理方式

使用systemd管理脚本，实现开机自启和异常自动重启：

```ini
# /etc/systemd/system/binlog-cleanup.service
[Unit]
Description=MySQL Binlog Auto Cleanup Daemon
After=mysql.service

[Service]
Type=simple
ExecStart=/path/to/clean_binlog.sh
Restart=on-failure
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
```

```bash
# 启用并启动服务
systemctl daemon-reload
systemctl enable binlog-cleanup
systemctl start binlog-cleanup

# 查看运行状态
systemctl status binlog-cleanup
```
