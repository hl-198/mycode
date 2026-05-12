使用方法
                                                                                                                                                                                             1. 修改脚本中的3个地方：

  - MYSQL_PASS — 填上你的MySQL密码
  - DB_LIST — 填上你所有的库名
  - OUTPUT_FILE — 输出文件名（默认 all_results.tsv）

  2. 执行：

  bash query_all_db.sh

  关键说明

  - 用 -B（batch模式）输出 TSV 格式，用Excel打开一样分列
  - 第一个库带表头，后续库只追加数据，不会重复表头
  - 如果想更安全地处理密码，可以改用 ~/.my.cnf：



