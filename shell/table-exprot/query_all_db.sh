#!/bin/bash

# MySQL 连接信息
MYSQL_HOST="db.ip"
MYSQL_USER="db.name"
MYSQL_PASS="db.passwd"   # 填密码，或通过 ~/.my.cnf 免密，或运行时通过环境变量 MYSQL_PWD 传入

# 库名列表（根据实际情况修改）
DB_LIST=(
    "db1"
    "db2"
    "db3"
    # 继续追加你的库名...
)

# 输出文件
OUTPUT_FILE="all_results.tsv"

# 如果不想明文写密码，可从环境变量读取
if [ -z "$MYSQL_PASS" ] && [ -n "$MYSQL_PWD" ]; then
    MYSQL_PASS="$MYSQL_PWD"
fi

FIRST=1
for DB in "${DB_LIST[@]}"; do
    echo "正在查询: $DB ..."
    if [ $FIRST -eq 1 ]; then
        # 第一个库：带表头
        mysql -u"$MYSQL_USER" -h"$MYSQL_HOST" -p"$MYSQL_PASS" -B -e \
            "SELECT '$DB' AS db_name, t.* FROM ${DB}.mmi_scanner_device t;" \
            > "$OUTPUT_FILE" 2>/dev/null
        FIRST=0
    else
        # 后续库：跳过表头
        mysql -u"$MYSQL_USER" -h"$MYSQL_HOST" -p"$MYSQL_PASS" -B -e \
            "SELECT '$DB' AS db_name, t.* FROM ${DB}.mmi_scanner_device t;" \
            | tail -n +2 >> "$OUTPUT_FILE" 2>/dev/null
    fi

    if [ $? -ne 0 ]; then
        echo "  [警告] $DB 查询失败，跳过"
    fi
done

echo "完成，结果输出到: $OUTPUT_FILE"
