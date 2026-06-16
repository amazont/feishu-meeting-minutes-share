export const meta = {
  name: 'daily-meeting-minutes',
  description: '把当日飞书妙记自动生成 5 维度会议纪要,独立 checker 打分校验(不达标自动重写),按天归档知识库并通知',
  whenToUse: '每天定时或手动触发,汇总当天所有飞书妙记为会议纪要文档,按天分目录归档',
  phases: [
    { title: 'Discover', detail: 'minutes +search 拉取今日妙记,读 ledger 去重(跳过已 DONE)' },
    { title: 'Draft', detail: '每篇取 notes/逐字稿 → 生成 5 维度 markdown 并写本地' },
    { title: 'Checker', detail: '独立只读 agent 按停止条件 C1–C4 打分,verdict<DONE 回灌缺口重写' },
    { title: 'Publish', detail: '在当天节点下建知识库文档' },
    { title: 'Notify', detail: '发飞书通知,附全部文档链接与 checker 分数' },
    { title: 'Persist', detail: '把结构化结果写 _result.json,供 wrapper 确定性落台账/刷 state' },
  ],
}

// ⚠️ 本脚本不含任何写死的个人配置。所有环境值由 wrapper 通过 args 传入:
//    args = { dayNode, localDir, openId, minuteHost, skipTokens, minScore, redraftMax }
//    - dayNode:    知识库当天容器节点 token(由 wrapper 用 bash 确定性创建/复用)
//    - localDir:   本地当天目录(由 wrapper 预建);_result.json 也写在这里
//    - openId:     飞书通知接收人 open_id
//    - minuteHost: 飞书域名,如 https://xxx.feishu.cn
//    - skipTokens: 逗号分隔的 token 列表,由 wrapper 确定性算出(已建文档的永久跳过 +
//                  当天 BLOCKED 已达放弃阈值的)。workflow 不读台账,只按此列表排除。
//    - minScore:   checker 合格阈值(默认 80)
//    - redraftMax: 额外重写次数(默认 1,即最多 2 稿)
const A = (typeof args === 'object' && args) ? args : {}
const DAY_NODE = A.dayNode
const OPEN_ID = A.openId
const MINUTE_HOST = A.minuteHost || ''
const SKIP = String(A.skipTokens || '').split(',').map(s => s.trim()).filter(Boolean)
const MIN_SCORE = Number(A.minScore) || 80
const REDRAFT_MAX = Number.isFinite(Number(A.redraftMax)) ? Number(A.redraftMax) : 1
if (!DAY_NODE || !OPEN_ID || !A.localDir) {
  throw new Error('缺少 args(dayNode/localDir/openId)。请通过 wrapper 脚本调用,不要直接裸跑。')
}
const LOCAL_DIR = A.localDir

const safe = (s) => s.replace(/[\\/:*?"<>|\\s]+/g, '_').slice(0, 40)

// 停止条件(loop-engine completion criteria):checker 以此为靶子打分
const CRITERIA = `C1 覆盖度:五个二级标题(总结/智能章节/关键决策/金句/相关链接)齐全且非空。
C2 正确性:总结与章节忠实于源妙记(notes/逐字稿),不臆造决策或金句。
C3 可验证性:相关链接指向有效 minute URL;标题为概括内容的 12-20 字,不是「某某的视频会议」这类默认名。
C4 一致性:Lark-flavored Markdown —— 首行 \`# 标题\`、含一个 <callout> 会议信息块、块之间有空行,飞书能正确渲染。`

const CHECK_SCHEMA = {
  type: 'object',
  properties: {
    score: { type: 'number' },
    per_criterion: { type: 'array', items: {
      type: 'object',
      properties: { id:{type:'string'}, criterion:{type:'string'}, status:{type:'string'}, evidence:{type:'string'} },
      required: ['id','status']
    }},
    gaps: { type: 'array', items: {
      type: 'object', properties: { id:{type:'string'}, desc:{type:'string'} }, required: ['desc']
    }},
    verdict: { type: 'string' },   // DONE | CONTINUE | BLOCKED
    notes: { type: 'string' },
  },
  required: ['score','verdict','gaps']
}

// 写结构化结果到 _result.json(workflow 自身无文件系统权限,借 agent 的 Write 工具落盘)
async function persist(resultObj) {
  phase('Persist')
  await agent(
    `用 Write 工具把下面这段 JSON **原样**写入文件 ${LOCAL_DIR}/_result.json(内容一字不改,不要包裹代码块):\n\n${JSON.stringify(resultObj, null, 2)}`,
    { phase: 'Persist' }
  )
}

// ① 发现:拉今日(owned ∪ participated)妙记,按 token 去重,再用 ledger 排除已 DONE 的
phase('Discover')
const discovery = await agent(
  `用 lark-cli 找出"今天"需要处理的飞书妙记。
1. 用 \`date +%Y-%m-%d\` 取今天日期 D。
2. 分别运行(均加 --format json):
   lark-cli minutes +search --owner-ids me --start D --end D --format json
   lark-cli minutes +search --participant-ids me --start D --end D --format json
3. 合并 data.items,按 token 去重。title 取 display_info 第一行。
4. 排除已处理/已放弃的妙记:从结果中剔除以下 token(逗号分隔,可能为空)——${SKIP.length ? SKIP.join(',') : '(无)'}。这些是已建文档(防重复建档)或当天已达放弃阈值的,不要再处理。
返回 date 和 minutes 数组(过滤后待处理的);没有待处理则 minutes 为空数组。`,
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
  // 高频心跳(如每 2 分钟)下,无新增时保持静默:不发飞书通知、不起额外 agent,
  // 只记一行日志,避免刷屏。真正有新增时才在 Notify 阶段汇总通知。
  log(`${discovery.date}: 无需处理的新妙记(无妙记或均已 DONE),静默跳过。`)
  return { date: discovery.date, count: 0, docs: [] }
}

// 单篇处理:Draft →(独立 Checker 打分 → 不达标按 gaps 重写,受 REDRAFT_MAX 预算约束)→ Publish
async function processOne(m) {
  const tail = m.token.slice(-6)
  const fname = `${discovery.date}_${safe(m.title)}.md`
  const path = `${LOCAL_DIR}/${fname}`

  const draft = async (gaps) => agent(
    `为飞书妙记生成会议纪要 markdown 并写入本地文件(本步骤不建飞书文档)。minute_token=${m.token},妙记原名「${m.title}」。
1. 运行 \`lark-cli vc +notes --minute-tokens ${m.token} --format json\` 取产物。
   - 有 artifacts.summary / artifacts.chapters → 直接基于它们写。
   - 只有 artifacts.transcript_file → 用 Read 完整读取该逐字稿,自己提炼总结与章节。
   - 完全取不到产物 → 在返回里把 fname 设为空字符串(表示 BLOCKED,无法生成)。
2. 拟一个概括会议内容的标题(12-20 字)。妙记原名常是"某某的视频会议"这类默认名,不要直接用。
3. 生成 Lark-flavored Markdown(否则飞书渲染会糊):
   - 第一行必须是 \`# <标题>\`(决定飞书文档标题);
   - 块之间必须空行分隔;
   - 一个 <callout> 块写会议信息,callout 内每行结尾加 <br/>;
   - 5 个二级标题:## 一、总结  ## 二、智能章节  ## 三、关键决策(表格)  ## 四、金句时刻(引用块)  ## 五、相关链接(放 ${MINUTE_HOST}/minutes/${m.token})
4. 用 Write 写到本地文件: ${path}(先 mkdir -p)。${gaps ? `
5. ⚠️ 上一稿被独立 checker 判定不达标。请针对性修复以下缺口后重写整篇(覆盖原文件):
${gaps.map((g,i)=>`   - ${g.desc}`).join('\n')}` : ''}
最后一个动作必须按 schema 返回 {title, fname}。无法生成时 fname 返回 ""。`,
    { label: `draft:${tail}`, phase: 'Draft', schema: {
        type: 'object', properties: { title:{type:'string'}, fname:{type:'string'} }, required: ['title','fname']
    }}
  )

  const check = async () => agent(
    `你是独立质量检查员(只读,只评不改,不要修改任何文件)。评审一篇已生成的会议纪要草稿是否达标。
草稿文件:${path}
源妙记 minute_token=${m.token}

步骤:
1. 用 Read 读取草稿文件全文。
2. 运行 \`lark-cli vc +notes --minute-tokens ${m.token} --format json\` 取源产物,用于核对草稿是否忠实(不要凭空相信草稿)。
3. 逐条对照停止条件打分:
${CRITERIA}
反作弊准则:能验就验(链接格式/五标题/首行#);partial 不算 pass;gap 必须可执行(写"补『三、关键决策』表格,源里有 X/Y 两项决策未收录",不写"质量需提升");怀疑从严。
4. 按 schema 返回 {score(0-100), per_criterion[], gaps[], verdict, notes}。verdict:全部 pass 且无臆造→DONE;有明确可补缺口→CONTINUE;取不到源/无法判定→BLOCKED。`,
    { label: `check:${tail}`, phase: 'Checker', schema: CHECK_SCHEMA }
  )

  // 首稿
  let d = await draft(null)
  if (!d || !d.fname) {
    return { token: m.token, title: m.title, url: '', score: 0, verdict: 'BLOCKED',
             gaps: [{ desc: '取不到妙记产物(notes/逐字稿),无法生成纪要' }] }
  }
  let title = d.title
  let v = await check()
  let attempts = 1
  // 重写预算:CONTINUE 且未达标且还有预算 → 按 gaps 重写;分数不升则停
  while (v && v.verdict === 'CONTINUE' && v.score < MIN_SCORE && attempts <= REDRAFT_MAX) {
    const d2 = await draft(v.gaps || [])
    if (!d2 || !d2.fname) break
    title = d2.title || title
    const v2 = await check()
    attempts++
    if (!v2 || v2.score <= v.score) { v = v2 || v; break }  // 无进展即停
    v = v2
  }

  const verdict = (v && v.score >= MIN_SCORE) ? 'DONE' : (v ? v.verdict : 'BLOCKED')

  // Publish(机械步骤,不改内容)
  const pub = await agent(
    `把本地 markdown 文件建成飞书知识库文档(挂当天节点下),机械步骤不改内容。
1. cd 到目录建文档(--content 必须相对路径;+create 不支持 --title/--format,标题取自 markdown 首行 #):
   cd "${LOCAL_DIR}" && lark-cli docs +create --api-version v2 --parent-token ${DAY_NODE} --doc-format markdown --content @./${fname}
2. 从返回 data.document.url 取链接。
3. 最后一个动作必须按 schema 返回 {url}。`,
    { label: `publish:${tail}`, phase: 'Publish', schema: {
        type: 'object', properties: { url:{type:'string'} }, required: ['url']
    }}
  )
  if (!pub || !pub.url) {
    return { token: m.token, title, url: '', score: v ? v.score : 0, verdict: 'BLOCKED',
             gaps: (v && v.gaps) || [{ desc: '建知识库文档失败' }] }
  }
  return { token: m.token, title, url: pub.url, score: v ? v.score : 0, verdict, gaps: (v && v.gaps) || [] }
}

const results = (await parallel(discovery.minutes.map(m => () => processOne(m)))).filter(Boolean)

// ④ 通知:仅当有成功归档时才发飞书(高频心跳下,纯 BLOCKED/无新增保持静默,避免刷屏)
phase('Notify')
const ok = results.filter(r => r.url)
const blocked = results.filter(r => !r.url)
if (ok.length > 0) {
  const lines = ok.map((r,i) => {
    const flag = r.verdict === 'DONE' ? '' : ` ⚠️ ${r.score}/100 待复核`
    return `${i+1}. [${r.title}](${r.url})${flag}`
  }).join('\\n')
  const tail = blocked.length > 0 ? `\\n\\n❌ 另有 ${blocked.length} 篇未能归档(取不到产物或建档失败),下次心跳会自动重试。` : ''
  await agent(
    `发飞书通知:
lark-cli im +messages-send --user-id ${OPEN_ID} --markdown "**📋 当日会议纪要已生成(${discovery.date},${ok.length}/${results.length} 篇归档)**\\n\\n${lines}${tail}"`,
    { phase: 'Notify' }
  )
} else {
  log(`本次无成功归档(${blocked.length} 篇 BLOCKED,下次心跳重试),静默不通知。`)
}

await persist({
  date: discovery.date, dayNode: DAY_NODE, minScore: MIN_SCORE,
  total: results.length, count: ok.length,
  docs: results.map(r => ({ token:r.token, title:r.title, url:r.url, score:r.score, verdict:r.verdict, gaps:(r.gaps||[]).map(g=>g.desc) })),
  blocked: blocked.map(r => ({ token:r.token, title:r.title, reason:(r.gaps&&r.gaps[0]&&r.gaps[0].desc)||'unknown' })),
})

return { date: discovery.date, dayNode: DAY_NODE, total: results.length, count: ok.length,
         docs: ok.map(r => ({ title:r.title, url:r.url, score:r.score, verdict:r.verdict })) }
