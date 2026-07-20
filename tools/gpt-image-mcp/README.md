# gpt-image-mcp（项目内置生图 MCP）

用 StepFun models-proxy 的 **gpt-image-2** 文生图的 MCP server（stdio）。
本目录随「每日会议纪要」项目分发：`./init.sh` 会自动安装依赖并注册到 Claude Code
（user scope，server 名 `gpt-image`），之后纪要 workflow 的 Publish agent
会按内容自行判断是否调用它给纪要配图（`config.sh` 里 `GEN_IMAGE=0` 可关闭）。

## 工具

- **`generate_image`** — 文生图,保存为本地 PNG 并返回路径。
  - `prompt`(必填,支持中文)、`size`(1024x1024 默认 / 1536x1024 / 1024x1536 / auto)、`n`(1-4)、
    `filename`(可选)、`out_dir`(可选,绝对路径)、`model`(默认 gpt-image-2)。

## 凭据来源(不硬编码)

按优先级:
1. 环境变量 `GPT_IMAGE_KEY` + `GPT_IMAGE_BASE_URL`(推荐:写在 `config.sh`,init.sh 注册时会带入 MCP 环境);
2. 否则从 `GPT_IMAGE_KEY_FILE`(默认 `~/项目/测试 key`)里正则解析 `ak-...` 与 base url。

⚠️ key 是明文,勿提交 git / 外发。没有 key 时工具会返回明确报错,纪要 workflow 会自动降级为无图发布。

## 手动注册(init.sh 失败时兜底)

```bash
cd tools/gpt-image-mcp && npm install
claude mcp add gpt-image --scope user -- node "$PWD/index.js"
claude mcp list        # 确认 gpt-image ✔ Connected
```

新注册的 MCP 需**重启 Claude Code 会话**后工具才可见(headless/cron 每次新起进程,天然生效)。

## 底层接口

`POST {base}/v1/images/generations`,body `{model, prompt, size, n}`,返回 `data[].b64_json`(或 `url`)。
models-proxy 还提供 gpt-image-1 / gpt-image-1.5 / dall-e-3 / gemini-*-image 等,换 `model` 即可用。
