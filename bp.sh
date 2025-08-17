#!/bin/bash
# Termux 备份与恢复脚本 - 纯 Bash 实现，无依赖
# 作者：根据用户文档编写
# 功能：支持轻量/常规/完整备份与恢复

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# =============== 配置区域 ===============
BACKUP_BASE="/sdcard/Download/termux-backup"
LOG_FILE="$BACKUP_BASE/backup_restore.log"

# =============== 工具函数 ===============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "❌ 错误: $*"
    exit 1
}

confirm() {
    read -rp "确认执行? (y/N): " choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# 添加容器状态检查函数
check_container_status() {
    local containers=()
    
    # 检查 proot-distro 是否安装
    if ! command -v proot-distro &> /dev/null; then
        echo "⚠️ proot-distro 未安装"

        return 1
    fi
    
    # 获取已安装的容器列表（解析 proot-distro list 输出）
    while IFS= read -r line; do
        if [[ "$line" == *"[installed]"* ]]; then
            # 提取容器名称（去掉星号和空格）
            containers+=("$(echo "$line" | awk '{print $1}' | sed 's/*//')")
        fi
    done < <(proot-distro list 2>/dev/null)
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        echo "未安装容器，请先安装容器后重试"
        return 1
    else
        echo "已安装: ${containers[*]}"
        return 0
    fi
}

# 添加容器状态显示函数
get_container_info() {
    local status=$(check_container_status)
    printf "📦 容器状态: %s\n" "$status"
}

# 添加外部存储状态检查函数
check_storage_status() {
    log "正在检查外部存储状态..."
    # 验证/sdcard目录是否存在且可写入
    if [[ -d "/sdcard" && -w "/sdcard" ]]; then
        log "✅ 外部存储已正常挂载"
        return 0
    else
        log "❌ 外部存储未挂载或不可写入"
        return 1
    fi
}

# 添加存储状态显示函数
get_storage_info() {
    if [[ -d "$BACKUP_BASE" ]]; then
        # 获取备份目录所在磁盘的使用情况（人类可读格式）
        df -h "$BACKUP_BASE" | awk 'NR==2 {
            printf "📊 外部存储状态: 可用 %s / 总计 %s (已使用 %s)\n", $4, $2, $5
        }'
    else
        echo "📊 外部存储状态: 目录不存在"
    fi
}

# =============== 初始化存储权限 ===============
setup_storage() {
    log "正在申请外部存储权限..."
    termux-setup-storage 2>/dev/null || true
    sleep 1
    # 检查存储状态，失败则退出
    check_storage_status || error_exit "外部存储初始化失败，请在系统设置中授予Termux存储权限后重试"
}

# =============== 创建备份目录 ===============
ensure_backup_dirs() {
    mkdir -p "$BACKUP_BASE/home" "$BACKUP_BASE/regular" "$BACKUP_BASE/full" || error_exit "无法创建备份目录"
}

# =============== 备份功能 ===============
backup_light() {
    local datestr=$(date +%Y%m%d_%H%M%S)
    local outfile="$BACKUP_BASE/home/home-backup-$datestr.tar.gz"
    local pkglist="$BACKUP_BASE/home/package-list-$datestr.txt"

    log "开始轻量备份：仅配置文件与包列表"
    log "备份目标: $outfile"

    # 切换到 Termux 根目录（包含 home 和 usr 的目录）
    cd /data/data/com.termux/files || error_exit "无法进入 Termux 根目录"
    
    if ! tar -zcvf "$outfile" -C "$HOME" . 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "配置文件备份失败"
    fi

    pkg list-installed > "$pkglist"
    log "✅ 安装包列表已保存至: $pkglist"
    log "✅ 轻量备份完成: $outfile"
}

# =============== 常规备份功能 ===============
backup_regular() {
    local datestr=$(date +%Y%m%d_%H%M%S)
    local outfile="$BACKUP_BASE/regular/termux-backup-$datestr.tar.gz"

    log "开始常规备份：home 和 usr 目录"
    log "备份目标: $outfile"

    # 切换到 Termux 根目录（包含 home 和 usr 的目录）
    cd /data/data/com.termux/files || error_exit "无法进入 Termux 根目录"
    
    if ! tar -zcvf "$outfile" home usr 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "常规备份失败"
    fi

    log "✅ 常规备份完成: $outfile"
}

# =============== 完整备份功能 ===============
backup_full() {
    local datestr=$(date +%Y%m%d_%H%M%S)
    local outfile="$BACKUP_BASE/full/termux-full-backup-$datestr.tar.gz"
    local container_dir="usr/var/lib/proot-distro"
    local tar_args=("home" "usr")
    local container_skipped=false  # 初始化容器跳过状态为false

    log "开始完整备份：home, usr, proot-distro 容器"
    log "备份目标: $outfile"

    # 切换到 Termux 根目录（包含 home 和 usr 的目录）
    cd /data/data/com.termux/files || error_exit "无法进入 Termux 根目录"
    
    # 检查容器目录是否存在
    if [[ -d "$container_dir" ]]; then
        log "检测到容器目录，添加到备份列表"
        tar_args+=("$container_dir")
    else
        log "⚠️ 未找到容器目录，跳过容器备份"
        container_skipped=true  # 容器目录不存在时设置为true
    fi
    
    # 执行备份（仅包含存在的目录）
    if ! tar -zcvf "$outfile" "${tar_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "完整备份失败"
    fi

    if [[ "$container_skipped" == true ]]; then
        log "⚠️ 注意：本次备份未包含容器数据，因为未找到容器目录"
    fi

    log "✅ 完整备份完成: $outfile"
}

# =============== 恢复功能 ===============
restore_light() {
    local infile=""
    local pkglist=""

    log "开始轻量恢复：配置文件 + 包列表重装"
    
    log "请选择轻量备份文件..."
    select_file "$BACKUP_BASE/home" "home-backup-*.tar.gz" infile
    
    if [[ -z "$infile" ]]; then
        log "⚠️ 未选择备份文件，轻量恢复已取消"
        return 1  # 返回非0值表示操作取消
    fi
    
    log "即将使用以下备份文件进行恢复: $infile"
    if ! confirm; then
        log "⚠️ 轻量恢复操作已取消"
        return 1
    fi

    # 修复：将备份文件名中的 "home-backup-" 替换为 "package-list-" 以匹配包列表文件名
    local base_name="${infile/home-backup-/package-list-}"
    pkglist="${base_name%.tar.gz}.txt"

    cd /data/data/com.termux/files || error_exit "无法进入 Termux 根目录"

    if ! tar -zxvf "$infile" -C "$HOME" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "配置文件恢复失败"
    fi

    if [[ -f "$pkglist" ]]; then
        log "正在重装软件包..."
        xargs pkg install -y < "$pkglist" 2>&1 | tee -a "$LOG_FILE"
    else
        log "⚠️ 未找到包列表，跳过重装"
    fi

    log "✅ 轻量恢复完成"
}

# =============== 常规恢复功能 ===============
restore_regular() {
    local infile=""

    log "开始常规恢复：home 和 usr 目录"
    
    log "请选择常规备份文件..."
    select_file "$BACKUP_BASE/regular" "termux-backup-*.tar.gz" infile
    
    if [[ -z "$infile" ]]; then
        log "⚠️ 未选择备份文件，常规恢复已取消"
        return 1  # 返回非0值表示操作取消
    fi

    log "即将使用以下备份文件进行恢复: $infile"
    if ! confirm; then
        log "⚠️ 常规恢复操作已取消"
        return 1
    fi


    cd /data/data/com.termux/files || error_exit "无法进入 Termux 根目录"

    if ! tar -zxvf "$infile" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "常规恢复失败"
    fi

    log "✅ 常规恢复完成"
}

# =============== 完整恢复功能 ===============
restore_full() {
    local infile=""
    local container_restored=false  # 初始化容器恢复状态为 false

    log "开始完整恢复：包含 proot-distro 容器"
    
    log "请选择完整备份文件..."
    select_file "$BACKUP_BASE/full" "termux-full-backup-*.tar.gz" infile
    
    if [[ -z "$infile" ]]; then
        log "⚠️ 未选择备份文件，完整恢复已取消"
        return 1  # 返回非0值表示操作取消
    fi

    log "即将使用以下备份文件进行恢复: $infile"
    if ! confirm; then
        log "⚠️ 完整恢复操作已取消"
        return 1
    fi

    cd /data/data/com.termux/files || error_exit "无法进入 Termux 根目录"

    if ! tar -zxvf "$infile" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "完整恢复失败"
    fi

    # 恢复后检查容器目录是否存在
    if [[ -d "usr/var/lib/proot-distro" ]]; then
        container_restored=true  # 目录存在，标记为已恢复
    fi

    # 反转条件：容器目录不存在时才显示警告
    if [[ "$container_restored" == false ]]; then
        log "⚠️ 注意：本次恢复未包含容器数据，因为未找到容器目录"
    fi

    log "✅ 完整恢复完成"
}

# =============== 文件选择器（交互） ===============
select_file() {
    local dir="$1"
    local pattern="$2"
    local -n result_var="$3"
    local files=()
    local file

    result_var=""

    [[ ! -d "$dir" ]] && log "目录不存在: $dir" && return 1

    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$dir" -type f -name "$pattern" | sort -r)

    if [[ ${#files[@]} -eq 0 ]]; then
        log "在 $dir 中未找到匹配的备份文件"
        return 1
    fi

    log "找到以下备份文件："
    for i in "${!files[@]}"; do # 遍历文件数组
        printf "[%3d] %s\n" $((i+1)) "${files[i]}" # 打印文件编号和文件名
    done

    while true; do
        read -rp "请输入编号选择文件 (1-${#files[@]}) 或 0 取消: " num
        if [[ "$num" =~ ^[0-9]+$ ]]; then
            if [[ "$num" -eq 0 ]]; then
                log "取消选择"
                return 1
            elif [[ "$num" -ge 1 && "$num" -le ${#files[@]} ]]; then
                result_var="${files[num-1]}"
                log "已选择: $result_var"
                return 0
            else
                log "无效编号，请重试"
            fi
        else
            log "请输入数字"
        fi
    done
}

# =============== 备份文件列表查看函数 ===============
list_backup_files() {
    log "开始查看备份文件结构..."
    
    # 定义备份类型与目录的对应关系
    local backup_types=(
        "home:轻量备份"
        "regular:常规备份"
        "full:完整备份"
    )

    # 检查主备份目录是否存在
    if [[ ! -d "$BACKUP_BASE" ]]; then
        log "❌ 备份主目录不存在: $BACKUP_BASE"
        return 1
    fi

    echo -e "\n📂 ${BLUE}备份文件结构${RESET} (${BACKUP_BASE}):"
    echo "=================================="

    # 遍历所有备份类型目录
    for type in "${backup_types[@]}"; do
        local dir="${type%:*}"       # 提取目录名（home/regular/full）
        local name="${type#*:}"      # 提取显示名称（轻量备份/常规备份/完整备份）
        local full_path="$BACKUP_BASE/$dir"

        # 检查子目录是否存在
        if [[ ! -d "$full_path" ]]; then
            echo -e "  ${YELLOW}⚠️ $name 目录不存在${RESET}"
            continue
        fi

        # 获取目录内的备份文件（按修改时间倒序）
        local files=()
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$full_path" -maxdepth 1 -type f | sort -r)

        # 显示目录信息和文件列表
        echo -e "\n  📁 ${GREEN}$name 目录${RESET} (${full_path}):"
        if [[ ${#files[@]} -eq 0 ]]; then
            echo "    ${YELLOW}无备份文件${RESET}"
        else
            for file in "${files[@]}"; do
                # 显示文件名和大小（人类可读格式）
                echo -n "    "
                ls -lh "$file" | awk '{print $5, $9}'
            done
        fi
    done

    echo -e "\n=================================="
    log "备份文件结构查看完成"
}

# =============== 子菜单功能 ===============
backup_menu() {
    local exit_status=0  # 初始化退出状态：0=直接返回主菜单，1=执行操作后返回
    while true; do
        clear
        echo -e "\033[31m████████╗███████╗██████╗ ███╗   ███╗██╗   ██╗██╗  ██╗\033[0m"
        echo -e "\033[32m╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║   ██║╚██╗██╔╝\033[0m"
        echo -e "\033[33m   ██║   █████╗  ██████╔╝██╔████╔██║██║   ██║ ╚███╔╝ \033[0m"
        echo -e "\033[34m   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║   ██║ ██╔██╗ \033[0m"
        echo -e "\033[35m   ██║   ███████╗██║  ██║██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗\033[0m"
        echo -e "\033[36m   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝\033[0m"
        echo "=================================="
        echo "        备份选项"
        echo "=================================="
        echo -e "$(get_storage_info)"  # 显示存储状态
        echo -e "$(get_container_info)"
        echo
        echo "[1] 📦 轻量备份 (配置+包列表)"
        echo "[2] 📦 常规备份 (home+usr)"
        echo "[3] 📦 完整备份 (home+usr+含容器)"
        echo "[0] ↩️ 返回主菜单"
        echo

        read -rp "请选择备份类型 [0-3]: " choice

        case "$choice" in
            1) backup_light; exit_status=1 ;;  # 执行操作后标记需按键提示
            2) backup_regular; exit_status=1 ;; # 执行操作后标记需按键提示
            3) backup_full; exit_status=1 ;;    # 执行操作后标记需按键提示
            0) break ;;  # 直接返回主菜单，状态码保持0
            *) log "无效选择，请重试" ;;
        esac

        # 仅当执行了操作（非直接返回）时显示按任意键提示
        if [[ "$exit_status" -eq 1 ]]; then
            echo
            read -n1 -r -s -p "按任意键继续..."
            exit_status=0  # 重置状态码，避免影响下次循环
        fi
    done

    return $exit_status  # 返回退出状态给主菜单
}

# 恢复子菜单
restore_menu() {
    local exit_status=0  # 初始化退出状态：0=直接返回主菜单，1=执行操作后返回
    while true; do
        clear
        echo -e "\033[31m████████╗███████╗██████╗ ███╗   ███╗██╗   ██╗██╗  ██╗\033[0m"
        echo -e "\033[32m╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║   ██║╚██╗██╔╝\033[0m"
        echo -e "\033[33m   ██║   █████╗  ██████╔╝██╔████╔██║██║   ██║ ╚███╔╝ \033[0m"
        echo -e "\033[34m   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║   ██║ ██╔██╗ \033[0m"
        echo -e "\033[35m   ██║   ███████╗██║  ██║██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗\033[0m"
        echo -e "\033[36m   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝\033[0m"
        echo "=================================="
        echo "        恢复选项"
        echo "=================================="
        echo -e "$(get_storage_info)"  # 显示存储状态
        echo -e "$(get_container_info)"
        echo
        echo "[1] 🔁 轻量恢复"
        echo "[2] 🔁 常规恢复"
        echo "[3] 🔁 完整恢复"
        echo "[0] ↩️ 返回主菜单"
        echo

        read -rp "请选择恢复类型 [0-3]: " choice


        case "$choice" in
            1) restore_light; exit_status=1 ;;  # 执行操作后标记需按键提示
            2) restore_regular; exit_status=1 ;; # 执行操作后标记需按键提示
            3) restore_full; exit_status=1 ;;    # 执行操作后标记需按键提示
            0) break ;;  # 直接返回主菜单，状态码保持0
            *) log "无效选择，请重试" ;;  # 无效选择不改变状态码
        esac

        # 仅当执行了恢复操作（非直接返回）时显示按键提示
        if [[ "$exit_status" -eq 1 ]]; then
            echo
            read -n1 -r -s -p "按任意键继续..."
            exit_status=0  # 重置状态码，避免下次循环误判
        fi
    done

    return $exit_status  # 返回状态码给主菜单
}

# =============== 主菜单 ===============
main_menu() {
    while true; do
        clear
        echo -e "\033[31m████████╗███████╗██████╗ ███╗   ███╗██╗   ██╗██╗  ██╗\033[0m"
        echo -e "\033[32m╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║   ██║╚██╗██╔╝\033[0m"
        echo -e "\033[33m   ██║   █████╗  ██████╔╝██╔████╔██║██║   ██║ ╚███╔╝ \033[0m"
        echo -e "\033[34m   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║   ██║ ██╔██╗ \033[0m"
        echo -e "\033[35m   ██║   ███████╗██║  ██║██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗\033[0m"
        echo -e "\033[36m   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝\033[0m"
        echo "=================================="
        echo "     🔧 Termux 备份与恢复工具"
        echo "=================================="
        echo -e "$(get_storage_info)"  # 显示存储状态
        echo -e "$(get_container_info)"
        echo
        echo "[1] 📦 备份选项"
        echo "[2] 🔁 恢复选项"
        echo "[3] 📋 查看备份文件"
        echo "[0] 🚪 退出"
        echo

        read -rp "请选择操作 [0-3]: " choice

        case "$choice" in
            1) backup_menu ;;
            2) restore_menu ;;
            3) list_backup_files; menu_status=1 ;;  # 调用新函数查看备份文件
            0) log "再见，G Boy！" && exit 0 ;;
            *) log "无效选择，请重试" ;;
        esac

        # 仅在子菜单非0退出时显示按任意键提示（操作完成场景）
        if [[ $menu_status -ne 0 ]]; then
            echo
            read -n1 -r -s -p "按任意键返回主菜单..."
        fi
    done
}

# =============== 启动入口 ===============
main() {
    setup_storage
    ensure_backup_dirs

    log "脚本启动，准备进入主菜单"

    main_menu
}

# =============== 运行 ===============
main "$@"