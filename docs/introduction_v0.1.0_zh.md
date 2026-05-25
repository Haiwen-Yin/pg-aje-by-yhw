# pg-aje 中文介绍

pg-aje 是一个 PostgreSQL 扩展，用于将关系型数据映射为 JSON 文档，并支持基于 ETAG 的乐观并发控制。它通过 JSON 文档视图提供对关系数据的双向读写访问，使得文档式的 CRUD 操作可以自动传播到底层表。

纯 PL/pgSQL 实现，无需 C 编译。

## 核心概念

### AJE 视图是什么？

AJE 视图（A JSON Extension View）是一种特殊的 PostgreSQL 视图，它将一个或多个关系表的数据组装为一份层次化的 JSON 文档：

- **读取**：从关系表查询数据，组装为 JSON 文档输出（单个 `data` JSONB 列）
- **写入**：对视图执行 INSERT / UPDATE / DELETE 时，触发器自动将操作拆解并传播到底层表
- **并发**：每次更新/删除前校验 ETAG，防止覆盖其他事务的修改
- **零冗余**：数据始终存储在关系表中，JSON 文档在查询时动态生成

### 文档结构

每份 AJE 文档具有如下结构：

```json
{
  "_id": 1,
  "dept_name": "Engineering",
  "location": "Building A",
  "_metadata": {
    "etag": "a1b2c3d4e5f6...",
    "xmin": 12345
  },
  "staff": [
    {"emp_name": "Alice", "job": "Engineer"},
    {"emp_name": "Bob", "job": "Manager"}
  ]
}
```

| 字段 | 说明 |
|---|---|
| `_id` | 根表主键。IDENTITY 列自动生成；TEXT 主键为字符串；复合主键为 JSON 对象 |
| `_metadata.etag` | MD5 哈希，用于乐观并发控制 |
| `_metadata.xmin` | PostgreSQL xmin，作为并发控制的后备机制 |

## 功能特性

| 特性 | 说明 |
|---|---|
| **AJE 视图** | 将关系数据暴露为层次化 JSON 文档（单列 `data` JSONB） |
| **完整 CRUD** | 视图上的 INSERT / UPDATE / DELETE 自动传播到底层表 |
| **复合主键** | 支持多列主键，`_id` 为 JSON 对象 |
| **TEXT 主键** | 支持字符串等非整数类型的主键 |
| **JSONB 列** | 原生 JSONB 字段在文档中完整保留 |
| **ETAG 并发** | 基于 MD5 的乐观并发控制，防止丢失更新 |
| **嵌套数组** | 通过外键关联的 1:N 嵌套，支持多个嵌套数组 |
| **注解系统** | 细粒度控制哪些表/列可写 |
| **自动检测** | 不提供字段列表时，自动发现表的所有列 |
| **深度合并** | `aje.jsonb_deep_merge()` 实现 RFC 7396 JSON Merge Patch |

## 主键处理

| 主键类型 | 文档中 `_id` 格式 | INSERT 行为 |
|---|---|---|
| `BIGINT GENERATED ALWAYS AS IDENTITY` | 整数，自动赋值 | 不提供 `_id`，由数据库自动生成 |
| `BIGINT NOT NULL` | 整数 | 必须在文档中提供 `_id` |
| `TEXT PRIMARY KEY` | 字符串 | 必须在文档中提供 `_id` |
| 复合主键（多列） | JSON 对象 | 必须提供 `_id`，如 `{"col1": val1, "col2": val2}` |

对于嵌套子表中的复合外键，所有 FK 列自动从根文档 `_id` 中填充。

## 注解系统

注解控制视图各级的写入权限：

| 注解 | 默认值 | 含义 |
|---|---|---|
| `insert` | `false` | 允许通过视图 INSERT |
| `update` | `false` | 允许通过视图 UPDATE |
| `delete` | `false` | 允许通过视图 DELETE |
| `check` | `true` | 将列值纳入 ETAG 计算 |
| `noinsert` | — | `insert` 的否定 |
| `noupdate` | — | `update` 的否定 |
| `nodelete` | — | `delete` 的否定 |
| `nocheck` | — | `check` 的否定，从 ETAG 中排除 |

### 行为说明

- **只读视图**（`insert:false, update:false, delete:false`）：对视图执行写操作时抛出异常（`aje_insert_blocked` / `aje_update_blocked` / `aje_delete_blocked`）
- **nodelete 子表**（子表 `delete:false`）：删除父行时，子表外键置 NULL（孤儿化），而非级联删除

## 使用方法

### 安装

```bash
psql -d your_database -f sql/install.sql
```

### 创建视图

```sql
-- 显式定义字段
SELECT aje.create_view(
    'dept_dv',           -- 视图名称
    'departments',        -- 根表名
    'public',             -- 根表所属 schema
    'd',                  -- 根表别名
    '{"insert":true,"update":true,"delete":true}'::jsonb,  -- 根表注解
    '[                    -- 字段列表
        {"path": "dept_name", "column": "dept_name", "updatable": true},
        {"path": "location", "column": "location", "updatable": true},
        {"path": "staff", "type": "nested_array",
         "table": "employees", "alias": "e",
         "annotations": {"insert": true, "update": true, "delete": true},
         "link": {"fk_columns": ["dept_id"], "pk_columns": ["dept_id"]},
         "fields": [
            {"path": "emp_name", "column": "emp_name", "updatable": true},
            {"path": "job", "column": "job", "updatable": true}
         ]}
    ]'::jsonb
);

-- 自动检测（所有列，全部可写）
SELECT aje.create_view('simple_dv', 'my_table');
```

### 查询文档

```sql
-- 查看完整文档
SELECT jsonb_pretty(data) FROM dept_dv;

-- 提取字段
SELECT data->>'dept_name' FROM dept_dv WHERE (data->>'_id')::bigint = 1;
```

### 插入文档

```sql
-- IDENTITY 主键：_id 自动生成
INSERT INTO dept_dv (data) VALUES (
    '{"dept_name": "Research", "location": "Boston",
      "staff": [{"emp_name": "Alice", "job": "Engineer"}]}'::jsonb
);

-- TEXT 主键：必须提供 _id
INSERT INTO group_dv (data) VALUES ('{"_id": "g1", "group_name": "Dev Team"}'::jsonb);

-- 复合主键：_id 为 JSON 对象
INSERT INTO item_dv (data) VALUES (
    '{"_id": {"item_id": 1, "item_type": "PRODUCT"}, "title": "Widget"}'::jsonb
);
```

### 更新文档

```sql
-- 更新根表字段
UPDATE dept_dv SET data = jsonb_set(data, '{location}', '"New York"')
WHERE (data->>'_id')::bigint = 1;

-- 替换嵌套数组（删除并重新插入策略）
UPDATE dept_dv SET data = jsonb_set(data, '{staff}',
    '[{"emp_name": "Alice", "job": "Senior Engineer"}]'::jsonb
) WHERE (data->>'_id')::bigint = 1;

-- 更新 JSONB 字段
UPDATE item_dv SET data = jsonb_set(data, '{tags}', '{"color":"red"}'::jsonb)
WHERE (data->'_id'->>'item_id')::bigint = 1;
```

### 删除文档

```sql
DELETE FROM dept_dv WHERE (data->>'_id')::bigint = 1;
```

### 视图管理

```sql
SELECT * FROM aje.list_views();              -- 列出所有视图
SELECT jsonb_pretty(aje.describe_view('dept_dv'));  -- 查看视图定义
SELECT * FROM aje.validate_view('dept_dv');  -- 校验视图
SELECT aje.drop_view('dept_dv');             -- 删除视图
```

### 卸载

```bash
psql -d your_database -f sql/uninstall.sql
```

## API 参考

| 函数 | 用途 |
|---|---|
| `aje.create_view(name, table, schema, alias, annotations, fields)` | 创建 AJE 视图及自动触发器 |
| `aje.drop_view(name)` | 删除 AJE 视图及所有关联对象 |
| `aje.list_views()` | 列出所有已注册视图 |
| `aje.describe_view(name)` | 返回视图结构的 JSONB 描述 |
| `aje.validate_view(name)` | 校验视图定义与实际表结构的一致性 |
| `aje.compute_etag(values)` | 从文本数组计算 MD5 ETAG |
| `aje.jsonb_deep_merge(target, patch)` | 递归深度 JSON 合并 |

## 架构

| 组件 | 实现机制 |
|---|---|
| 视图生成 | `jsonb_build_object()` + 关联子查询 |
| 可更新性 | `INSTEAD OF` 触发器（含子查询的视图不可自动更新） |
| ETAG | `md5()` 哈希 check 注解列值 + `xmin` |
| 嵌套数组 | `jsonb_agg()` 关联子查询，基于外键 |
| 更新策略 | 嵌套数组采用删除并重新插入 |
| 删除策略 | 级联删除或外键置 NULL（按注解） |
| 复合主键 | `_id` 为 JSON 对象，WHERE 子句使用 `OLD.data->'_id'->>'col'` 内联表达式 |
| 动态类型 | `v_root_id` 类型（bigint / text）根据列 data_type 动态决定 |

## 项目结构

```
pg-aje-by-yhw/
├── sql/
│   ├── install.sql          — 目录表 + 核心函数
│   └── uninstall.sql        — 清理脚本
├── scripts/
│   ├── install.sh           — 安装脚本
│   └── test/
│       └── test_aje.sql     — SQL 测试套件
├── docs/
│   └── introduction_v0.1.0_zh.md — 中文介绍
├── CHANGELOG.md
├── LICENSE
├── NOTICE
├── README.md
└── RELEASE_NOTES.md
```

## 当前限制（v0.1.0）

- 仅支持 1:N 嵌套数组（N:1、N:N 待 v0.2.0）
- 仅支持单层嵌套（根 + 一级子表）
- 无 GraphQL 语法解析器，仅支持函数式 API
- 无 flex columns 支持
- 无计算字段（`@generated`）
- 无 WHERE 过滤谓词
- 无 REST / 文档 API 集成
- 嵌套数组更新采用删除并重新插入策略（无增量差异）

## 许可证

Apache License 2.0 — 见 [LICENSE](../LICENSE) 和 [NOTICE](../NOTICE)。

## 作者

尹海文