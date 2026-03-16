修改脚本user@ip为实际的用户名和ip,并且配置服务器免密登陆,设置每5分钟执行一次
#!/bin/bash
# 获取远程服务器时间并调整
remote_time=$(ssh user@ip "date '+%Y-%m-%d %H:%M:%S'")
timestamp=$(date -d "$remote_time" +%s)
adjusted_timestamp=$((timestamp - 5))
new_time=$(date -d "@$adjusted_timestamp" "+%Y-%m-%d %H:%M:%S")

# 设置本地时间
sudo date -s "$new_time"
echo "已将本地时间设置为：$new_time"

配置免密登陆
cd /用户家目录/.ssh
ssh-keygen -t rsa -b 4096 -C "DMP服务器登录"
ssh-copy-id jfjkzs@10.50.230.245

配置定时任务
crontab -e 
每5分钟
*/5 * * * * /opt/date.sh



如果无法配置免密登录的情况下，使用这个版本的脚本，密码明文写在脚本中，安全性低，谨慎使用
#!/bin/bash
# 获取远程服务器时间并调整
remote_time=$(expect -c "
spawn ssh user@ip date '+%Y-%m-%d %H:%M:%S'
expect {
    \"password:\" { send \"your_password\r\"; exp_continue }
    eof
}
")
# 提取出实际的时间字符串
remote_time=$(echo "$remote_time" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')
timestamp=$(date -d "$remote_time" +%s)
adjusted_timestamp=$((timestamp - 5))
new_time=$(date -d "@$adjusted_timestamp" "+%Y-%m-%d %H:%M:%S")

# 设置本地时间
sudo date -s "$new_time"
echo "已将本地时间设置为：$new_time"
