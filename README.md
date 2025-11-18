# godeploy

GitHub Release 部署工具，支持 Golang + Nodejs 的 CI/CD

## 使用方法

```bash
# ==== 安装 godeploy 命令 ====
# 安装最新稳定版 (最常用)
curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash
# 安装特定版本 (用于回滚或测试)
# 安装 v0.0.0.3 版本
curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash -s v0.0.0.4

# 验证安装
godeploy --version
# 获取帮助
godeploy --help

# ==== 创建 godeploy 配置文件 ====
# cd 到工作目录，执行 godeploy init 命令，创建 godeploy.env 配置文件
cd /srv/app/my-app
godeploy init
# 对应修改 godeploy 配置文件

# ==== 准备 golang 应用的 .env 环境变量（如果有）====
micro .env

# ==== 准备 systemd unit（一次性）====
/etc/systemd/system/my-app.service

# ==== 启动 ====
godeploy
```