#!/bin/bash
#===============================================================================
# 脚本名称: upgrade_dm_driver.sh
# 功能描述: 批量替换达梦数据库驱动(Driver)与方言(Dialect)文件，并自动备份旧版本。
# 版本信息: v2.0 (生产发布版 - 并行加速 + 动态时间戳)
# 适用环境: Linux (CentOS/Ubuntu/RedHat等)
# 依赖工具: bash, date, cp, mv, dirname
# 作者提示: 请在执行前确认 NEW_DRIVER 和 NEW_DIALECT 路径正确。
#===============================================================================

set -o pipefail # 确保管道中任何一个命令失败都返回错误码

#-------------------------------------------------------------------------------
# [配置区] - 请根据实际部署环境修改以下变量
#-------------------------------------------------------------------------------

# 1. 动态生成备份后缀 (格式: YYYYMMDD_HHMMSS)
#    作用：确保每次运行脚本生成的备份文件名唯一，防止覆盖历史备份。
BACK_SUFFIX="$(date +%Y%m%d_%H%M%S)"

# 2. 新版本文件路径 (源文件)
#    注意：请确保这两个文件存在且具备读取权限。建议使用绝对路径。
NEW_DRIVER="./new_libs/DmJdbcDriver8.jar"
NEW_DIALECT="./new_libs/DmDialect-for-hibernate6.6.jar"

# 3. 旧版驱动文件列表 (目标替换路径)
#    说明：数组格式，支持相对路径或绝对路径。脚本将遍历此列表进行替换。
#    提示：路径已做混淆处理，请替换为您服务器上的真实路径。
OLD_DRIVERS=(
    "./app/server/libs/dm/DmJdbcDriver-18.jar"
    "./app/server/modules/dsv/lib/DmJdbcDriver-18.jar"
    "./runtime/3rd-party/DmJdbcDriver18.jar"
    "./tools/deploy/data/runtime/3rd/DmJdbcDriver18.jar"
    "./tools/deploy/dbo/3rd/DmJdbcDriver18.jar"
    "./tools/deploy/metadata/runtime/3rd/DmJdbcDriver18.jar"
    "./tools/dmpdep/IDI/lib/DmJdbcDriver18.jar"
    "./tools/emc/runtime/3rd/DmJdbcDriver18.jar"
    "./tools/setup/libs/3rd/DmJdbcDriver18.jar"
    "./tools/update/runtime/3rd/DmJdbcDriver18.jar"
)

# 4. 旧版方言文件列表 (目标替换路径)
OLD_DIALECTS=(
    "./app/server/libs/dm/DmDialect-for-hibernate5.3-8.1.3.140.jar"
    "./app/server/modules/dsv/lib/DmDialect-for-hibernate-5.3.jar"
    "./runtime/3rd-party/DmDialect-for-hibernate5.3.jar"
    "./tools/deploy/dbo/3rd/DmDialect-for-hibernate5.3.jar"
    "./tools/deploy/metadata/runtime/3rd/DmDialect-for-hibernate5.3.jar"
    "./tools/dmpdep/IDI/lib/DmDialect-for-hibernate5.3.jar"
)

# 5. 性能调优参数
#    MAX_PARALLEL: 最大并行进程数。
#    建议值：本地SSD设为 10-20，机械硬盘或网络存储(NFS)设为 2-5，防止IO阻塞。
MAX_PARALLEL=10

#-------------------------------------------------------------------------------
# [全局变量] - 运行时状态记录
#-------------------------------------------------------------------------------
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_FILES=()

#-------------------------------------------------------------------------------
# [辅助函数]
#-------------------------------------------------------------------------------

# 函数：打印带颜色的日志
# 参数: $1=类型(INFO/SUCCESS/WARN/ERROR), $2=消息内容
log_msg() {
    local type="$1"
    local msg="$2"
    local color=""
    
    case "$type" in
        "INFO")    color="\033[0;34m" ;; # 蓝色
        "SUCCESS") color="\033[0;32m" ;; # 绿色
        "WARN")    color="\033[0;33m" ;; # 黄色
        "ERROR")   color="\033[0;31m" ;; # 红色
        *)         color="\033[0m" ;;
    esac
    
    echo -e "${color}[$(date '+%H:%M:%S')] [$type] ${msg}\033[0m"
}

# 函数：清理函数 (脚本退出时触发)
cleanup() {
    # 如果有需要清理的临时文件，可在此添加
    :
}

# 注册退出信号处理，确保脚本被中断时也能输出总结
trap cleanup EXIT
trap 'echo -e "\n\033[0;31m⚠️  脚本被用户中断!\033[0m"; exit 130' INT TERM

#-------------------------------------------------------------------------------
# [核心逻辑]
#-------------------------------------------------------------------------------

# 函数：处理单个文件 (备份 + 替换)
# 参数: $1=旧文件路径, $2=新文件路径, $3=备份后缀
process_single_file() {
    local old_file="$1"
    local new_file="$2"
    local suffix="$3"
    
    # 1. 预检查：如果旧文件不存在，直接跳过 (视为成功，无需操作)
    if [[ ! -f "$old_file" ]]; then
        return 0
    fi

    local dir=$(dirname "$old_file")
    local backup_name="${old_file}.${suffix}"

    # 2. 备份操作 (mv)
    #    注意：mv 在同一分区是原子操作，速度极快；跨分区则是复制+删除
    if ! mv "$old_file" "$backup_name" 2>/dev/null; then
        echo "ERROR:${old_file}" # 通过 stdout 返回错误标记
        return 1
    fi

    # 3. 替换操作 (cp)
    #    将新文件复制到旧文件所在目录
    if ! cp "$new_file" "$dir/" 2>/dev/null; then
        # 如果复制失败，尝试回滚备份，保证系统不处于“文件丢失”状态
        mv "$backup_name" "$old_file" 2>/dev/null
        echo "ERROR:${old_file}"
        return 1
    fi
    
    # 成功则无输出，减少进程间通信开销
    return 0
}

# 函数：并行任务控制器
# 参数: $1=任务类型名称, $2=新文件路径, $3...=旧文件列表
run_parallel_tasks() {
    local task_type="$1"
    local new_file="$2"
    shift 2
    local files=("$@")
    
    log_msg "INFO" "开始处理任务组：${task_type} (共 ${#files[@]} 个文件)"

    # 前置检查：新文件必须存在
    if [[ ! -f "$new_file" ]]; then
        log_msg "ERROR" "❌ 致命错误：新文件不存在 -> ${new_file}"
        log_msg "ERROR" "   该任务组已跳过，请检查路径配置。"
        ((FAIL_COUNT++))
        FAILED_FILES+=("${task_type}: 新文件缺失 (${new_file})")
        return 1
    fi

    local active_pids=()
    local processed=0
    
    for file in "${files[@]}"; do
        # 启动后台子进程处理单个文件
        # 使用子shell包裹，以便捕获返回值
        (
            result=$(process_single_file "$file" "$new_file" "$BACK_SUFFIX")
            if [[ "$result" == ERROR:* ]]; then
                exit 1
            fi
            exit 0
        ) &
        
        local pid=$!
        active_pids+=("$pid:$file")
        ((processed++))

        # --- 并发流控逻辑 ---
        # 当活跃进程数达到阈值时，等待任意一个进程结束，释放槽位
        while (( ${#active_pids[@]} >= MAX_PARALLEL )); do
            # 等待任意一个后台作业完成
            wait -n 2>/dev/null || true
            
            # 重新清理已完成进程的数组 (简单实现：重新收集所有仍在运行的PID)
            local new_pids=()
            for item in "${active_pids[@]}"; do
                local p_id="${item%%:*}"
                if kill -0 "$p_id" 2>/dev/null; then
                    new_pids+=("$item")
                fi
            done
            active_pids=("${new_pids[@]}")
        done
    done

    # 等待剩余所有后台进程完成，并收集结果
    for item in "${active_pids[@]}"; do
        local p_id="${item%%:*}"
        local p_file="${item#*:}"
        
        if ! wait "$p_id"; then
            ((FAIL_COUNT++))
            FAILED_FILES+=("${p_file}")
            log_msg "ERROR" "❌ 处理失败: ${p_file}"
        else
            ((SUCCESS_COUNT++))
        fi
    done

    log_msg "SUCCESS" "✅ 任务组 [${task_type}] 完成。成功: $((processed - FAIL_COUNT)), 失败: $FAIL_COUNT (当前批次)"
}

#-------------------------------------------------------------------------------
# [主程序入口]
#-------------------------------------------------------------------------------

main() {
    # 1. 启动横幅
    echo "==============================================================================="
    echo "🚀 达梦驱动/方言 自动化升级脚本 (Parallel Version)"
    echo "==============================================================================="
    log_msg "INFO" "当前备份后缀：${BACK_SUFFIX}"
    log_msg "INFO" "最大并发数：${MAX_PARALLEL}"
    log_msg "INFO" "工作目录：$(pwd)"
    echo "-------------------------------------------------------------------------------"

    # 2. 权限预检 (可选：检查是否由 root 运行，如果不是且目标目录需要权限，则警告)
    if [[ $EUID -ne 0 ]]; then
        # 简单检查：尝试写入第一个目标文件的目录，如果失败则提示
        # 这里不做强制退出，因为可能只是部分目录需要 sudo
        : 
    fi

    # 记录开始时间 (纳秒精度)
    local start_time=$(date +%s.%N)

    # 3. 执行任务
    #    注意：两个任务组串行执行 (先换完驱动，再换方言)，组内并行
    run_parallel_tasks "数据库驱动 (Driver)" "$NEW_DRIVER" "${OLD_DRIVERS[@]}"
    run_parallel_tasks "Hibernate 方言 (Dialect)" "$NEW_DIALECT" "${OLD_DIALECTS[@]}"

    # 4. 计算耗时
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    # 5. 最终报告
    echo "==============================================================================="
    printf "📊 执行总结:\n"
    printf "   总耗时：%.3f 秒\n" "$duration"
    printf "   成功数：%d\n" "$SUCCESS_COUNT"
    printf "   失败数：%d\n" "$FAIL_COUNT"
    
    if (( FAIL_COUNT > 0 )); then
        echo -e "\n\033[0;31m⚠️  以下文件处理失败，请人工介入:\033[0m"
        for f in "${FAILED_FILES[@]}"; do
            echo "   - $f"
        done
        echo ""
        echo "💡 回滚提示:"
        echo "   若需回滚，请执行以下命令 (将 .${BACK_SUFFIX} 后缀移除):"
        echo "   find . -name '*.${BACK_SUFFIX}' -exec sh -c 'mv \"\$1\" \"\${1%.${BACK_SUFFIX}}\"' _ {} \;"
        exit 1
    else
        log_msg "SUCCESS" "🎉 所有文件替换成功！系统已就绪。"
        exit 0
    fi
}

# 执行主函数
main "$@"
