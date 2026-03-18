# Ai_shell
项目中使用Ai写的自用shell脚本备份

# manage.sh （感谢Qwen3.5 plus）
本脚本是一款专为生产环境设计的“零依赖”微服务集群管理工具。它摒弃了传统的
PID 文件记录方式，采用基于 /proc 文件系统、lsof 端口检测和 pgrep 特征匹配的
实时状态感知技术。即使在进程异常崩溃、非正常退出或子进程残留等复杂场景下，
依然能精准识别服务状态并执行清理操作。
只需调整122行 服务配置区 (Service Configuration) 内容即可使用

💡 设计理念:
1. Port is Truth (端口即真理): 对于网络服务，端口监听是判断服务可用的唯一金标准。
2. Context-Aware (上下文感知): 智能区分“启动中”、“已就绪”和“假死”状态。
3. Zero-Maintenance (零维护): 首次运行自动完成所有环境配置，无需人工干预。
4. Defensive Coding (防御性编程): 严格的白名单校验，防止误操作生产环境。


# 服务器巡检脚本 （感谢copilot）
实现多服务器自动抓取服务器配置和应用信息


# update_date.sh （感谢豆包）
有些时候接口调用对于两台服务器的时间差要求简直是丧心病狂，这个脚本用于同步目标服务器时间后减掉5秒设置为本机的时间，时间差可以调整


# universal_cleaner.sh （感谢Qwen3.5 plus）
1. FILE 模式：递归全量清理指定后缀的旧文件
2. FOLDER 模式：智能增量清理带日期命名的旧文件夹
3. 安全机制：双重校验（文件名日期 + 实际修改时间），防止误删
4. 自维护：自动清理脚本自身的历史运行日志
5. 使用方法脚本内有说明，详情看脚本注释
6. 调用方法：
   crontab -e
   添加以下内容，代表每天凌晨2点执行一次脚本，注意修改脚本路径
   0 2 * * * /path/to/universal_cleaner.sh >> /var/log/universal_cleaner_logs/cron.log 2>&1


# upgrade_dm_driver.sh 和 rollback_dm_driver.sh （感谢Qwen3.5 plus）
功能描述: 批量替换达梦数据库驱动(Driver)与方言(Dialect)文件，并自动备份旧版本。
请在执行前确认 NEW_DRIVER 和 NEW_DIALECT 路径正确。

脚本名称: rollback_dm_driver.sh
功能描述: 紧急回滚达梦数据库驱动与方言文件到最近的备份版本。



# init_server.sh （感谢Qwen3.5 plus）
Linux 服务器自动化初始化与加固工具

适用于 CentOS / Rocky / AlmaLinux / Ubuntu / Kylin (麒麟) / UOS (统信) 等主流 Linux 发行版。它通过交互式的问答引导，自动完成从网络配置到安全加固的全套流程，确保每一台新上线的服务器都符合统一的安全基线和运维规范。
