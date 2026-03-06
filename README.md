# aytool

Docker 多架构构建 CLI 工具。交互选择项目、自动版本递增、自动登录 Registry、实时构建输出。

## 安装

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayou129/aytool/master/install.sh)"
```

安装后重启终端，或执行 `source ~/.zshrc`。

## 配置

### 方式一：导入配置文件

将以下格式保存为 `.conf` 文件，然后导入：

```
[config]
REGISTRY=ccr.ccs.tencentyun.com
REGISTRY_USER=your_username
REGISTRY_PASS=your_password
NAMESPACE=your_namespace
PLATFORM=linux/x86_64,linux/arm64/v8
ENV_FILE=/path/to/your/.env

[projects]
myapp|MYAPP_VERSION|myapp_image|~/projects/myapp||
frontend|FRONTEND_VERSION|frontend_image|~/projects|frontend/Dockerfile|shared=~/libs
```

```bash
aytool import ~/path/to/my.conf
```

### 方式二：交互式编辑

```bash
aytool config               # 编辑全局配置（Registry、平台等）
aytool project add           # 添加新项目
aytool project               # 编辑已有项目
```

### 字段说明

**config**

| 字段 | 说明 |
|------|------|
| REGISTRY | Docker Registry 地址 |
| REGISTRY_USER | 登录用户名 |
| REGISTRY_PASS | 登录密码 |
| NAMESPACE | 镜像命名空间 |
| PLATFORM | 构建平台（逗号分隔） |
| ENV_FILE | 版本号所在的 .env 文件路径 |

**projects.conf** — 每行一个项目，`|` 分隔：

```
别名|ENV变量名|镜像名|构建目录|Dockerfile路径(可选)|构建上下文(可选)
```

## 使用

```bash
aytool build                # 交互选择项目
aytool build myapp          # 构建 myapp，版本自动 +1
aytool build myapp 5        # 构建 myapp，指定版本 5
aytool project              # 交互式编辑项目配置
aytool project add          # 添加新项目
aytool project rm myapp     # 删除项目
aytool config               # 交互式编辑全局配置
aytool list                 # 列出所有项目 + 当前版本
aytool pull myapp           # 输出 docker pull 命令
aytool import my.conf       # 从文件导入配置
aytool init                 # 生成默认配置文件
aytool update               # 检查并更新到最新版本
aytool version              # 显示当前版本
aytool help                 # 显示帮助
```

### 构建流程

```
1. 检测 Docker Registry 登录状态 → 未登录则自动登录
2. 从 .env 读取当前版本 → 计算新版本
3. 展示确认面板（项目、版本、镜像、平台）
4. 确认后执行 docker buildx build --platform ... --push
5. 构建成功 → 更新 .env 版本号
6. 输出 pull 命令
```

## 测试

```bash
zsh test_aytool.zsh
```

测试覆盖纯逻辑函数：版本比较、项目解析/序列化、版本读写、项目持久化。

## 更新

```bash
aytool update    # 检查并更新到最新版本
```

工具会在每次执行命令后异步检查是否有新版本，如果有会在终端提示。
