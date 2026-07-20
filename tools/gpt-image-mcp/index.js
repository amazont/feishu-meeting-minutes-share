#!/usr/bin/env node
// gpt-image-mcp — 用 StepFun models-proxy 的 gpt-image-2 生图的 MCP server(stdio)。
// key 不硬编码:从环境变量 GPT_IMAGE_KEY 读,或从 GPT_IMAGE_KEY_FILE 指向的文件里解析 ak-... 与 base url。
// 生成的图默认存到 GPT_IMAGE_OUT_DIR(默认 ~/项目/飞书文档/generated-images),返回本地路径。

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, isAbsolute } from 'node:path'

const DEFAULT_BASE = 'https://models-proxy.stepfun-inc.com'
const KEY_FILE = process.env.GPT_IMAGE_KEY_FILE || join(homedir(), '项目', '测试 key')
const OUT_DIR = process.env.GPT_IMAGE_OUT_DIR || join(homedir(), '项目', '飞书文档', 'generated-images')

// 解析凭据:优先环境变量,否则从 key 文件里正则抠出 base url 和 ak- key。
function resolveCreds() {
  let base = process.env.GPT_IMAGE_BASE_URL || ''
  let key = process.env.GPT_IMAGE_KEY || ''
  if (!key || !base) {
    try {
      const txt = readFileSync(KEY_FILE, 'utf8')
      if (!base) base = (txt.match(/https?:\/\/[^\s]+/) || [])[0] || DEFAULT_BASE
      if (!key) key = (txt.match(/ak-[A-Za-z0-9_-]+/) || [])[0] || ''
    } catch { /* 文件不存在则依赖环境变量 */ }
  }
  base = (base || DEFAULT_BASE).replace(/\/+$/, '')
  return { base, key }
}

function safeSlug(s) {
  return (s || 'image').replace(/[\\/:*?"<>|\s]+/g, '_').replace(/[^\w一-龥_-]/g, '').slice(0, 40) || 'image'
}

const server = new McpServer({ name: 'gpt-image-mcp', version: '1.0.0' })

server.registerTool(
  'generate_image',
  {
    title: '生成图片 (gpt-image-2)',
    description: '用 StepFun models-proxy 的 gpt-image-2 文生图。给定 prompt(可含中文)生成一张图,保存为本地 PNG 并返回文件路径。需要出图时调用。',
    inputSchema: {
      prompt: z.string().describe('图像描述提示词,支持中文;越具体越好(主体/风格/构图/配色/背景)'),
      size: z.enum(['1024x1024', '1536x1024', '1024x1536', 'auto']).default('1024x1024').describe('图像尺寸,默认 1024x1024'),
      n: z.number().int().min(1).max(4).default(1).describe('生成数量,1-4,默认 1'),
      filename: z.string().optional().describe('可选:输出文件名(不含扩展名);缺省用 prompt 生成'),
      out_dir: z.string().optional().describe('可选:输出目录绝对路径;缺省用 GPT_IMAGE_OUT_DIR'),
      model: z.string().default('gpt-image-2').describe('模型名,默认 gpt-image-2;也可用 gpt-image-1.5 等'),
    },
  },
  async ({ prompt, size, n, filename, out_dir, model }) => {
    const { base, key } = resolveCreds()
    if (!key) {
      return { isError: true, content: [{ type: 'text', text: `未找到 API key。请在 ${KEY_FILE} 放置 ak- 开头的 key,或设置环境变量 GPT_IMAGE_KEY。` }] }
    }
    const dir = out_dir || OUT_DIR
    mkdirSync(dir, { recursive: true })

    let resp
    try {
      resp = await fetch(`${base}/v1/images/generations`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model, prompt, size, n }),
      })
    } catch (e) {
      return { isError: true, content: [{ type: 'text', text: `请求失败(网络/代理):${e.message}` }] }
    }
    const raw = await resp.text()
    let data
    try { data = JSON.parse(raw) } catch { return { isError: true, content: [{ type: 'text', text: `响应非 JSON(HTTP ${resp.status}):${raw.slice(0, 400)}` }] } }
    if (!resp.ok || data.error) {
      const msg = data.error ? (data.error.message || JSON.stringify(data.error)) : `HTTP ${resp.status}`
      return { isError: true, content: [{ type: 'text', text: `生图接口报错:${msg}` }] }
    }
    const items = data.data || []
    if (!items.length) return { isError: true, content: [{ type: 'text', text: '接口未返回任何图像。' }] }

    const stamp = `${size}_${items.length}`  // 不用 Date(避免时区/确定性问题),用尺寸+张数区分
    const baseName = safeSlug(filename || prompt)
    const saved = []
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      const suffix = items.length > 1 ? `_${i + 1}` : ''
      const fpath = join(dir, `${baseName}_${stamp}${suffix}.png`)
      if (it.b64_json) {
        writeFileSync(fpath, Buffer.from(it.b64_json, 'base64'))
        saved.push(fpath)
      } else if (it.url) {
        try {
          const img = await fetch(it.url)
          const buf = Buffer.from(await img.arrayBuffer())
          writeFileSync(fpath, buf)
          saved.push(fpath)
        } catch (e) {
          saved.push(`(下载失败,原始 URL) ${it.url}`)
        }
      }
    }
    return {
      content: [{
        type: 'text',
        text: `已用 ${model} 生成 ${saved.length} 张图,保存到:\n${saved.map(p => '- ' + p).join('\n')}`,
      }],
    }
  }
)

const transport = new StdioServerTransport()
await server.connect(transport)
