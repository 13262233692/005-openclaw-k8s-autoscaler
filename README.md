# Open Claw - Kubernetes Test Environment Automation CLI

Open Claw 是一个用于 Kubernetes 测试环境自动化运维的 CLI 工具，采用纯 Shell 脚本结合少量 Python 胶水代码的多文件架构。

## 架构概览

项目采用清晰的三层架构设计：

```
┌─────────────────────────────────────────────────┐
│              参数解析层 (Parser)                │
│   命令路由分发 / 选项解析 / 帮助信息             │
├─────────────────────────────────────────────────┤
│              业务逻辑层 (Business)              │
│   优雅重启 / HPA 管理 / 状态查询                 │
├─────────────────────────────────────────────────┤
│              API 调用层 (API)                   │
│   kubectl 封装 / JSON 解析 / 集群通信           │
├─────────────────────────────────────────────────┤
│              审计记录层 (Audit & Record)        │
│   Webhook 审计 / 执行链路追踪 / 结构化输出       │
└─────────────────────────────────────────────────┘
```

## 目录结构

```
openclaw/
├── bin/
│   └── openclaw              # 主入口脚本
├── lib/                      # Shell 库模块
│   ├── utils.sh              # 工具函数与日志
│   ├── parser.sh             # 参数解析层 - 命令路由分发
│   ├── api.sh                # API 调用层 - kubectl 封装
│   ├── status.sh             # 状态查询业务
│   ├── restart.sh            # 优雅重启业务模块
│   ├── hpa.sh                # HPA 动态配置业务模块
│   ├── webhook.sh            # Webhook 审计模块
│   └── trace.sh              # 执行链路追踪模块
├── models/
│   └── execution_trace.py    # Python 胶水代码 - 执行链路模型
├── config/
│   └── config.sh             # 全局配置
└── records/                  # 执行记录输出目录
```

## 功能特性

### 1. 命令路由分发
- 标准 CLI 子命令结构
- 全局选项与子命令选项分离
- 完善的帮助信息

### 2. 底层通信模块
- 封装 `kubectl` 命令
- 统一 JSON 输出解析
- 支持节点、Pod、Deployment、HPA 等资源操作

### 3. 容器优雅重启 (Graceful Restart)
- 按部署名 / 标签选择器 / 全量重启
- 可配置优雅关机周期
- 批处理重启，控制并发
- 失败自动回滚
- 重启前后状态验证

### 4. HPA 动态配置管理
- HPA 列表与详情查询
- CPU / Memory 阈值动态修改
- Min / Max 副本数调整
- HPA 禁用 / 启用
- 实时指标查看

### 5. Webhook 审计
- 所有变更同步调用 Webhook
- 支持 curl 和 Python urllib 两种 HTTP 客户端
- 可配置超时时间
- 可通过环境变量开关

### 6. 执行链路模型记录
- 结构化 JSON 输出
- Trace ID 全链路追踪
- 步骤级状态记录
- 事件级审计日志
- 按日期归档存储
- Python 模型类提供丰富的查询接口

## 快速开始

### 环境要求
- Bash 4.0+
- kubectl（已配置集群访问）
- Python 3.6+（可选，用于增强的 JSON 处理和模型操作）
- jq（可选，用于 JSON 解析）

### 安装

```bash
# 克隆或下载项目
cd openclaw

# 添加执行权限
chmod +x bin/openclaw
chmod +x models/execution_trace.py

# 可选：添加到 PATH
export PATH="$(pwd)/bin:$PATH"
```

### 配置

通过环境变量或直接修改 `config/config.sh` 进行配置：

| 环境变量 | 默认值 | 说明 |
|---------|-------|------|
| `OPENCLAW_KUBECTL_NAMESPACE` | `default` | 默认命名空间 |
| `OPENCLAW_WEBHOOK_URL` | - | Webhook 审计端点 URL |
| `OPENCLAW_WEBHOOK_ENABLED` | `true` | 是否启用 Webhook |
| `OPENCLAW_WEBHOOK_TIMEOUT` | `10` | Webhook 超时时间（秒） |
| `OPENCLAW_GRACEFUL_PERIOD` | `30` | 默认优雅关机周期（秒） |
| `OPENCLAW_RESTART_BATCH_SIZE` | `1` | 默认重启批次大小 |
| `OPENCLAW_HPA_CPU_THRESHOLD` | `80` | 默认 CPU 阈值 |
| `OPENCLAW_HPA_MEMORY_THRESHOLD` | `80` | 默认内存阈值 |
| `OPENCLAW_RECORDS_DIR` | `./records` | 执行记录目录 |

## 使用指南

### 查看帮助

```bash
openclaw help
openclaw help restart
openclaw help hpa
```

### 查看集群状态

```bash
# 查看所有状态
openclaw status

# 仅查看节点
openclaw status nodes

# JSON 格式输出
openclaw status pods -o json

# 实时监控模式
openclaw status hpa -w --interval 10
```

### 优雅重启

```bash
# 重启单个 Deployment
openclaw restart my-app

# 按标签选择器重启
openclaw restart -l app=web --grace-period 60

# 重启命名空间下所有 Deployment
openclaw restart --all -n production

# 批处理重启，每批 2 个，间隔 10 秒
openclaw restart --all --batch-size 2 --interval 10

# 失败自动回滚
openclaw restart my-app --rollback

# 试运行模式（不实际执行）
openclaw restart my-app --dry-run
```

### HPA 管理

```bash
# 列出所有 HPA
openclaw hpa list

# 查看 HPA 详情
openclaw hpa get -n my-hpa

# 修改 CPU 和内存阈值
openclaw hpa set-threshold -n my-hpa --cpu 70 --memory 75

# 修改副本数范围
openclaw hpa set-replicas -n my-hpa --min 2 --max 20

# 禁用 HPA（设置固定副本数）
openclaw hpa disable -n my-hpa --replicas 3
```

### 审计记录

```bash
# 列出最近的执行记录
openclaw audit -l

# 查看特定记录详情
openclaw audit -s <trace-id>

# 列出更多记录，JSON 格式输出
openclaw audit -l --limit 50 --format json
```

## 执行链路模型

每次执行都会生成结构化的执行链路记录，保存在 `records/YYYY-MM-DD/trace_<id>.json`。

### Trace 数据结构

```json
{
  "trace_id": "1234567890-abc123",
  "version": "1.0.0",
  "command": "restart",
  "args": ["my-app"],
  "start_time": "2024-01-01T00:00:00.000Z",
  "end_time": "2024-01-01T00:00:30.000Z",
  "status": "success",
  "exit_code": 0,
  "context": {
    "namespace": "default",
    "operator": "user",
    "host": "hostname"
  },
  "steps": [
    {
      "step_id": "verify_deployment",
      "step_type": "verify",
      "status": "success",
      "description": "Verifying deployment exists",
      "start_time": "...",
      "end_time": "..."
    }
  ],
  "events": [
    {
      "event_id": "...",
      "timestamp": "...",
      "event_type": "restart",
      "resource_type": "deployment",
      "resource_name": "my-app",
      "status": "completed",
      "details": {...}
    }
  ],
  "results": {
    "success_count": "1",
    "failed_count": "0"
  }
}
```

### 使用 Python 模型

```python
from models.execution_trace import ExecutionTrace, TraceManager

# 加载 Trace
manager = TraceManager("./records")
trace = manager.load_trace("trace-id-here")

# 获取摘要
print(trace.summary())

# 遍历步骤
for step in trace.steps:
    print(f"{step.step_id}: {step.status}")

# 列出所有 Trace
traces = manager.list_traces(limit=10)
```

也可以直接使用 CLI：

```bash
python models/execution_trace.py --list --summary
python models/execution_trace.py --show <trace-id>
python models/execution_trace.py --cleanup 30
```

## Webhook 审计

所有变更操作都会发送 Webhook 事件到配置的 URL。

### Webhook Payload 示例

```json
{
  "event_id": "evt_abc123",
  "trace_id": "1234567890-abc123",
  "timestamp": "2024-01-01T00:00:00.000Z",
  "source": "open-claw",
  "version": "1.0.0",
  "event_type": "restart",
  "resource": {
    "type": "deployment",
    "name": "my-app",
    "namespace": "default"
  },
  "status": "completed",
  "details": {
    "grace_period": "30",
    "pre_replicas": "3",
    "post_replicas": "3"
  },
  "operator": {
    "user": "username",
    "host": "hostname"
  },
  "dry_run": false
}
```

## 模块说明

### 参数解析层 (`lib/parser.sh`)
- 命令注册与路由分发
- 全局选项解析
- 帮助信息生成

### API 调用层 (`lib/api.sh`)
- 底层 kubectl 命令封装
- JSON 输出解析
- 统一错误处理
- 资源 CRUD 操作

### 业务模块
- **restart.sh**: 优雅重启业务逻辑
- **hpa.sh**: HPA 动态配置管理
- **status.sh**: 集群状态查询

### 审计记录层
- **webhook.sh**: Webhook 事件发送
- **trace.sh**: 执行链路追踪（Shell 端）
- **execution_trace.py**: 执行链路模型（Python 端）

## 许可

MIT License
