# godeploy

GitHub Release 部署工具

## 使用方法

```bash
# ==== 安装 godeploy 命令 ====
# 安装最新稳定版 (最常用)
curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash
# 安装特定版本 (用于回滚或测试)
# 安装 v0.0.0.3 版本
curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash -s v0.0.0.4

# 

# ==== 创建 godeploy 配置文件 ====

```

## AI 汇总

### 1）安装命令

```bash
sudo cp godeploy /usr/local/bin/godeploy
sudo chmod +x /usr/local/bin/godeploy
```

### 2）准备目录与配置

```bash
sudo mkdir -p /srv/app/ha
sudo chown -R $USER:$USER /srv/app/ha

cd /srv/app/ha
# 写 godeploy.env（上面的例子）
nano godeploy.env

# 写 app.env（应用用）
nano app.env
```

### 3）写 systemd unit（一次性）

`/etc/systemd/system/ha-agent.service`：

```ini
[Unit]
Description=HA Agent Service
After=network.target

[Service]
User=youruser
Group=youruser
WorkingDirectory=/srv/app/ha/current
ExecStart=/srv/app/ha/current/ha-agent
EnvironmentFile=/srv/app/ha/app.env
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable ha-agent
```

### 4）首次部署 / 发布新版本

Release 中，tag `v1.0.0` 下有一个资产名为 `ha-agent` 的二进制。

```bash
cd /srv/app/ha
godeploy v1.0.0
```

### 5）回滚版本

```bash
cd /srv/app/ha
godeploy v1.0.1   # 升级
godeploy v1.0.0   # 回滚，只要 Release 里还保留这个版本
```

## 安装命令

```bash
# 安装最新稳定版 (最常用)
curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash
# 安装特定版本 (用于回滚或测试)
# 安装 v0.0.0.3 版本
curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash -s v0.0.0.4

```