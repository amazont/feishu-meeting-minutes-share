export const meta = {
  name: 'daily-meeting-minutes',
  description: '把当日飞书妙记自动生成 5 维度会议纪要并按天归档到知识库,最后发飞书通知',
  whenToUse: '每天定时或手动触发,汇总当天所有飞书妙记为会议纪要文档,按天分目录归档',
  phases: [
    { title: 'Discover', detail: 'minutes +search 拉取今日妙记并去重' },
    { title: 'Draft', detail: '每篇取 notes/逐字稿 → 生成 5 维度 markdown 并写本地' },
    { title: 'Publish', detail: '在当天节点下建知识库文档' },
    { title: 'Notify', detail: '发飞书通知,附全部文档链接' },
  ],
}

// ⚠️ 本脚本不含任何写死的个人配置。所有环境值由 wrapper 通过 args 传入:
//    args = { dayNode, localDir, openId, minuteHost }
//    - dayNode:    知识库当天容器节点 token(由 wrapper 用 bash 确定性创建/复用)
//    - localDir:   本地当天目录(由 wrapper 预建)
//    - openId:     飞书通知接收人 open_id
//    - minuteHost: 飞书域名,如 https://xxx.feishu.cn
const A = (typeof args === 'object' && args) ? args : {}
const DAY_NODE = A.dayNode
const OPEN_ID = A.openId
const MINUTE_HOST = A.minuteHost || ''
if (!DAY_NODE || !OPEN_ID || !A.localDir) {
  throw new Error('缺少 args(dayNode/localDir/openId)。请通过 wrapper 脚本调用,不要直接裸跑。')
}
const LOCAL_DIR = A.localDir

// ① 发现:用 lark-cli 拉今日(owned ∪ participated)妙记并去重
phase('Discover')
const discovery = await agent(
  `用 lark-cli 找出"今天"的所有飞书妙记并去重。
1. 用 \`date +%Y-%m-%d\` 取今天日期 D。
2. 分别运行(均加 --format json):
   lark-cli minutes +search --owner-ids me --start D --end D --format json
   lark-cli minutes +search --participant-ids me --start D --end D --format json
3. 合并 data.items,按 token 去重。title 取 display_info 第一行。
返回 date 和 minutes 数组;今天没有妙记则 minutes 为空数组。`,
  { phase: 'Discover', schema: {
      type: 'object',
      properties: {
        date: { type: 'string' },
        minutes: { type: 'array', items: {
          type: 'object',
          properties: { token: {type:'string'}, title: {type:'string'} },
          required: ['token','title']
        }}
      }, required: ['date','minutes']
  }}
)

if (!discovery.minutes || discovery.minutes.length === 0) {
  phase('Notify')
  await agent(
    `今天(${discovery.date})没有妙记。发飞书通知:
     lark-cli im +messages-send --user-id ${OPEN_ID} --text "📋 ${discovery.date} 今日无新飞书妙记,未生成会议纪要。"`,
    { phase: 'Notify' }
  )
  return { date: discovery.date, count: 0, docs: [] }
}

const safe = (s) => s.replace(/[\\/:*?"<>|\\s]+/g, '_').slice(0, 40)

// ②③ 两段式 pipeline:Draft(提炼并写本地) → Publish(在当天节点下建文档)
const docs = await pipeline(
  discovery.minutes,

  (m) => {
    const fname = `${discovery.date}_${safe(m.title)}.md`
    return agent(
      `为飞书妙记生成会议纪要 markdown 并写入本地文件(本步骤不建飞书文档)。minute_token=${m.token},妙记原名「${m.title}」。
1. 运行 \`lark-cli vc +notes --minute-tokens ${m.token} --format json\` 取产物。
   - 有 artifacts.summary / artifacts.chapters → 直接基于它们写。
   - 只有 artifacts.transcript_file → 用 Read 完整读取该逐字稿,自己提炼总结与章节。
2. 拟一个概括会议内容的标题(12-20 字)。妙记原名常是"某某的视频会议"这类默认名,不要直接用。
3. 生成 Lark-flavored Markdown(否则飞书渲染会糊):
   - 第一行必须是 \`# <标题>\`(决定飞书文档标题);
   - 块之间必须空行分隔;
   - 一个 <callout> 块写会议信息,callout 内每行结尾加 <br/>;
   - 5 个二级标题:## 一、总结  ## 二、智能章节  ## 三、关键决策(表格)  ## 四、金句时刻(引用块)  ## 五、相关链接(放 ${MINUTE_HOST}/minutes/${m.token})
4. 用 Write 写到本地文件: ${LOCAL_DIR}/${fname}(先 mkdir -p)。
5. 最后一个动作必须按 schema 返回 {title, fname}。`,
      { label: `draft:${m.token.slice(-6)}`, phase: 'Draft', schema: {
          type: 'object', properties: { title:{type:'string'}, fname:{type:'string'} }, required: ['title','fname']
      }}
    )
  },

  (draft) => {
    if (!draft || !draft.fname) return null
    return agent(
      `把本地 markdown 文件建成飞书知识库文档(挂当天节点下),机械步骤不改内容。
1. cd 到目录建文档(--content 必须相对路径;+create 不支持 --title/--format,标题取自 markdown 首行 #):
   cd "${LOCAL_DIR}" && lark-cli docs +create --api-version v2 --parent-token ${DAY_NODE} --doc-format markdown --content @./${draft.fname}
2. 从返回 data.document.url 取链接。
3. 最后一个动作必须按 schema 返回 {title, url}。title 用「${draft.title}」。`,
      { label: `publish`, phase: 'Publish', schema: {
          type: 'object', properties: { title:{type:'string'}, url:{type:'string'} }, required: ['title','url']
      }}
    )
  }
)

phase('Notify')
const ok = docs.filter(Boolean)
const missed = discovery.minutes.length - ok.length
const lines = ok.map((d,i) => `${i+1}. [${d.title}](${d.url})`).join('\\n')
const tail = missed > 0 ? `\\n\\n⚠️ 另有 ${missed} 篇处理失败,请手动检查。` : ''
await agent(
  `发飞书通知:
lark-cli im +messages-send --user-id ${OPEN_ID} --markdown "**📋 当日会议纪要已生成(${discovery.date},共 ${ok.length}/${discovery.minutes.length} 篇)**\\n\\n${lines}${tail}"`,
  { phase: 'Notify' }
)

return { date: discovery.date, dayNode: DAY_NODE, total: discovery.minutes.length, count: ok.length, docs: ok }
