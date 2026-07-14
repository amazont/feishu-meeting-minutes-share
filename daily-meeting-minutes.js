export const meta = {
  name: 'daily-meeting-minutes',
  description: '把当日飞书妙记自动生成结论前置式会议纪要(一句话结论/背景与目的/分议题讨论/决策/Action Items/待确认问题/链接/备注),独立 checker 打分校验(不达标自动重写),按天归档知识库并通知',
  whenToUse: '每天定时或手动触发,汇总当天所有飞书妙记为会议纪要文档,按天分目录归档',
  phases: [
    { title: 'Discover', detail: 'minutes +search 拉取今日妙记,读 ledger 去重(跳过已 DONE)' },
    { title: 'Draft', detail: '每篇取 notes/逐字稿 → 生成结论前置式纪要 markdown 并写本地' },
    { title: 'Checker', detail: '独立只读 agent 按停止条件 C1–C4 打分,verdict<DONE 回灌缺口重写' },
    { title: 'Publish', detail: '在当天节点下建知识库文档' },
    { title: 'Notify', detail: '发飞书通知,附全部文档链接与 checker 分数' },
    { title: 'Persist', detail: '把结构化结果写 _result.json,供 wrapper 确定性落台账/刷 state' },
  ],
}

// ⚠️ 本脚本不含任何写死的个人配置。所有环境值由 wrapper 通过 args 传入:
//    args = { dayNode, localDir, openId, minuteHost, skipTokens, minScore, redraftMax,
//             rubricFile, offlineInput, dryRun }
//    - dayNode:    知识库当天容器节点 token(由 wrapper 用 bash 确定性创建/复用)
//    - localDir:   本地当天目录(由 wrapper 预建);_result.json 也写在这里
//    - openId:     飞书通知接收人 open_id
//    - minuteHost: 飞书域名,如 https://xxx.feishu.cn
//    - skipTokens: 逗号分隔的 token 列表,由 wrapper 确定性算出(已建文档的永久跳过 +
//                  当天 BLOCKED 已达放弃阈值的)。workflow 不读台账,只按此列表排除。
//    - minScore:   checker 合格阈值(默认 80)
//    - redraftMax: 额外重写次数(默认 1,即最多 2 稿)
//    - rubricFile: (可选)checker 评分标准外置文件路径;传入时 checker 以该文件内容为准,
//                  未传或读不到时回退到脚本内置 CRITERIA。进化系统只改这个文件即可调 rubric。
//    - offlineInput:(可选)离线回归模式:golden case 目录(每个子目录 <token>/ 含
//                  transcript.md + meta.json)。启用后不调妙记 API、隐含 dryRun。
//    - dryRun:     (可选)true 时跳过 Publish 建档与 Notify 通知,产出只落本地。
let A = {}
if (args && typeof args === 'object') { A = args }
else if (typeof args === 'string' && args.trim()) { try { A = JSON.parse(args) } catch (e) { A = {} } }
const OFFLINE_DIR = String(A.offlineInput || '').trim()
const DRY_RUN = !!A.dryRun || !!OFFLINE_DIR
const DAY_NODE = A.dayNode || ''
const OPEN_ID = A.openId || ''
const MINUTE_HOST = A.minuteHost || ''
const RUBRIC_FILE = String(A.rubricFile || '').trim()
const SKIP = String(A.skipTokens || '').split(',').map(s => s.trim()).filter(Boolean)
const MIN_SCORE = Number(A.minScore) || 80
const REDRAFT_MAX = Number.isFinite(Number(A.redraftMax)) ? Number(A.redraftMax) : 1
if (!A.localDir) {
  throw new Error('缺少 args.localDir。请通过 wrapper 脚本调用,不要直接裸跑。')
}
if (!DRY_RUN && (!DAY_NODE || !OPEN_ID)) {
  throw new Error('缺少 args(dayNode/openId)。生产模式必须由 wrapper 传入;离线回归请用 offlineInput/dryRun。')
}
const LOCAL_DIR = A.localDir

const safe = (s) => s.replace(/[\\/:*?"<>|\\s]+/g, '_').slice(0, 40)

// 停止条件(loop-engine completion criteria):checker 以此为靶子打分
const CRITERIA = `C1 覆盖度:七个必备二级标题(一、一句话结论/二、背景与目的/三、分议题讨论/四、形成的决策/五、Action Items/六、需要继续确认的问题/七、相关链接)齐全且非空;「八、备注」可选,存在则须非空。
C2 正确性:各段内容忠实于源妙记(notes/逐字稿),不臆造结论、决策、待办或开放问题;「一句话结论」必须是"这个会定了什么方向/得出什么判断"的提炼,不是议程复述。
C3 可验证性:相关链接指向有效 minute URL;首行标题格式为「# YYYY-MM-DD 概括标题 会议纪要」,中间的概括标题 10-20 字且不是「某某的视频会议」这类默认名。
C4 一致性/排版:Lark-flavored Markdown —— 首行 \`# 标题\`、一个 <callout> 会议信息块(每行单个 <br/> 分隔、不用 <br/><br/>)、块之间有空行;「三、分议题讨论」按议题/发言人用「### 三级标题 + 叙事段落 + 要点列表」组织,不得按时间戳机械切片、不得把整段正文挤进单个列表项;「四、形成的决策」是有序编号列表(1. 2. 3.),每条一句完整判断,不用表格;「五、Action Items」是三列表格 | 负责人 | 待办事项 | 时间节点 |,单元格不含 <br/> 与 @用户/<cite> 提及标记,负责人写纯姓名文本;飞书能正确渲染。`

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
//    离线回归模式(offlineInput):不调妙记 API,直接枚举 golden case 目录。
phase('Discover')
const discovery = await agent(
  OFFLINE_DIR
    ? `离线回归模式:枚举 golden case 目录 ${OFFLINE_DIR} 下的所有子目录(每个子目录名即 minute token)。
1. 运行 \`ls "${OFFLINE_DIR}"\` 列出子目录。
2. 对每个子目录,用 Read 读取其中的 meta.json,取 title 字段(读不到 meta.json 则 title 用目录名)。
3. 排除以下 token(逗号分隔,可能为空)——${SKIP.length ? SKIP.join(',') : '(无)'}。
返回 date(用 \`date +%Y-%m-%d\` 取今天)和 minutes 数组 [{token, title}];目录为空则 minutes 为空数组。`
    : `用 lark-cli 找出"今天"需要处理的飞书妙记。
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

// 确定性去重兜底:skipTokens 原先只写进了 Discover 的 prompt,LLM 可能无视它、把已处理的妙记又返回来
// (2026-07-06 事故:当天唯一一篇被每 2 分钟重复生成 12+ 次,每轮各推一条飞书通知)。
// 去重是确定性判定,不能托付给模型自觉——这里在代码层强制过滤。
if (discovery && Array.isArray(discovery.minutes) && SKIP.length) {
  const before = discovery.minutes.length
  discovery.minutes = discovery.minutes.filter(m => m && !SKIP.includes(m.token))
  const removed = before - discovery.minutes.length
  if (removed > 0) log(`代码层强制剔除 ${removed} 篇已处理/已放弃妙记(skipTokens 兜底,防重复建档)`)
}

if (!discovery.minutes || discovery.minutes.length === 0) {
  // 高频心跳(如每 2 分钟)下,无新增时保持静默:不发飞书通知。
  // 但仍写 _result.json 作为"完成契约"——wrapper 据此判定本次真正跑完,
  // 避免被 stepcode 收尾反馈问卷导致的假退出码(130)误判为失败。
  log(`${discovery.date}: 无需处理的新妙记(无妙记或均已 DONE/跳过),静默跳过。`)
  await persist({ date: discovery.date, dayNode: DAY_NODE, total: 0, count: 0, docs: [], blocked: [] })
  return { date: discovery.date, dayNode: DAY_NODE, total: 0, count: 0, docs: [], blocked: [] }
}

// 单篇处理:Draft →(独立 Checker 打分 → 不达标按 gaps 重写,受 REDRAFT_MAX 预算约束)→ Publish
async function processOne(m) {
  const tail = m.token.slice(-6)
  const fname = `${discovery.date}_${safe(m.title)}.md`
  const path = `${LOCAL_DIR}/${fname}`

  // 源产物读取指令:生产走妙记 API;离线回归直接读 golden case 的逐字稿
  const SRC_STEP = OFFLINE_DIR
    ? `1. 用 Read 完整读取逐字稿 ${OFFLINE_DIR}/${m.token}/transcript.md,自己提炼总结与章节。
   - 文件不存在或为空 → 在返回里把 fname 设为空字符串(表示 BLOCKED,无法生成)。`
    : `1. 运行 \`lark-cli vc +notes --minute-tokens ${m.token} --format json\` 取产物。
   - 有 artifacts.summary / artifacts.chapters → 直接基于它们写。
   - 只有 artifacts.transcript_file → 用 Read 完整读取该逐字稿,自己提炼总结与章节。
   - 完全取不到产物 → 在返回里把 fname 设为空字符串(表示 BLOCKED,无法生成)。`

  const draft = async (gaps) => agent(
    `为飞书妙记生成会议纪要 markdown 并写入本地文件(本步骤不建飞书文档)。minute_token=${m.token},妙记原名「${m.title}」。
${SRC_STEP}
2. 拟一个概括会议内容的标题(10-20 字)。妙记原名常是"某某的视频会议"这类默认名,不要直接用。
3. 生成 Lark-flavored Markdown(严格按下面结构,否则飞书渲染会糊;每个块之间都要有空行)。总原则:**结论前置、议题驱动**——先给"这个会定了什么",再按议题/人展开,不按时间轴机械切片:
   - 第一行必须是「# ${discovery.date} 标题 会议纪要」(井号+空格,日期前置,决定飞书文档标题)。
   - 紧接一个 callout 写会议信息:<callout emoji="💡">会议名称:…<br/>会议时间:…<br/>参会人员:…<br/>会议性质:…</callout>。每行结尾只加一个 <br/>、最后一行不加;不要用 <br/><br/>(会多出空行)。"会议性质"用一短语概括会议类型(如"周例会/方案评审/专项对齐/信息同步")。
   - 随后二级标题,顺序固定,各自排版如下:

     ## 一、一句话结论
     —— 2–4 句,直接讲清"这个会定了什么方向、得出什么判断、接下来重心是什么"。这是全文最重要的段落,先给答案再给过程;不要写成议程复述。

     ## 二、背景与目的
     —— 1–3 段叙事,交代为什么开这个会:触发点、要解决的问题、此前的上下文与判断逻辑。源里信息多就成段写透,信息少就 1–2 句中性概述,不要臆造。

     ## 三、分议题讨论  【重点,务必照此排版】
     —— 按**议题或发言人/模块**组织,不按时间戳切片。每个议题用三级标题:
        ### 议题小标题(或「某人:主题」)
        (下面)1–2 段叙事讲清讨论脉络与判断,再视信息量接无序列表列要点;叙事与列表混排,别通篇只有列表。
     —— 源 artifacts.chapters 有时间戳时,可在三级标题后接 \`mm:ss–mm:ss\`(行内代码、– 连接),取不到就不写。
     —— 自适应:短会/纯信息同步(逐字稿短、无多议题)允许退化为 3–5 个要点段,不硬凑议题;长会/战略会按完整议题结构写。
     —— 严禁把「标题+时间+正文」挤进同一个列表项;严禁用有序列表「1. 」直接承载整段正文(会糊成一堵墙)。

     ## 四、形成的决策
     —— 有序编号列表(1. 2. 3.),每条一句完整判断,讲清"定了什么、口径是什么"。这是"会上拍板/达成共识"层面,区别于待办;若无明确决策,写一行「本次以信息同步为主,无明确决策事项」。不用表格。

     ## 五、Action Items
     —— 三列 markdown 表格:| 负责人 | 待办事项 | 时间节点 |。一行一条行动项;单元格内不要换行、不要放 <br/>;负责人写纯姓名文本,不嵌 @用户/<cite> 提及标记;时间节点源里没有就写「未明确」;无明确待办写一行「本次无明确后续事项」。

     ## 六、需要继续确认的问题
     —— 无序列表,列出会上抛出但未定、需要后续对齐或另开会确认的开放问题,每条「- 」讲清"什么问题、卡在哪、等谁/等什么定"。确无遗留写一行「本次无遗留待确认问题」。

     ## 七、相关链接
     —— 无序列表一行:- 飞书妙记原文:${MINUTE_HOST}/minutes/${m.token}

     ## 八、备注(可选)
     —— 若会议有值得点出的底层共识、基调或对团队工作方式的要求,用一段话收束;短会/无此类内容时整段省略(连标题一起不写)。
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
2. ${OFFLINE_DIR
      ? `用 Read 完整读取源逐字稿 ${OFFLINE_DIR}/${m.token}/transcript.md,用于核对草稿是否忠实(不要凭空相信草稿)。`
      : `运行 \`lark-cli vc +notes --minute-tokens ${m.token} --format json\` 取源产物,用于核对草稿是否忠实(不要凭空相信草稿)。`}
3. 逐条对照停止条件打分:
${RUBRIC_FILE
      ? `   ⚠️ 评分标准已外置:先用 Read 读取 ${RUBRIC_FILE},以其中的 C1-C4 条目为唯一评分标准。读不到该文件时,回退用以下内置标准:
${CRITERIA}`
      : CRITERIA}
反作弊准则:能验就验(链接格式/必备七标题/首行 # 含日期前置);partial 不算 pass;gap 必须可执行(写"补『五、Action Items』表格,源里有 X/Y 两项行动项未收录",不写"质量需提升");怀疑从严。
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

  // dry-run/离线回归:不建飞书文档,产出只落本地。url 用 dryrun:// 前缀标记,
  // 让 _result.json 的 count 统计与回归断言仍能区分"生成成功"与 BLOCKED。
  if (DRY_RUN) {
    return { token: m.token, title, url: `dryrun://${fname}`, score: v ? v.score : 0, verdict, gaps: (v && v.gaps) || [] }
  }

  // Publish(机械步骤,不改内容)
  const pub = await agent(
    `把本地 markdown 文件建成飞书知识库文档(挂当天节点下),机械步骤不改内容。
1. cd 到目录建文档(--content 必须相对路径;+create 不支持 --title/--format,标题取自 markdown 首行 #):
   cd "${LOCAL_DIR}" && lark-cli docs +create --as user --api-version v2 --parent-token ${DAY_NODE} --doc-format markdown --content @./${fname}
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
if (DRY_RUN) {
  log(`dry-run:跳过飞书通知(${ok.length}/${results.length} 篇生成成功)。`)
} else if (ok.length > 0) {
  const lines = ok.map((r,i) => {
    const flag = r.verdict === 'DONE' ? '' : ` ⚠️ ${r.score}/100 待复核`
    return `${i+1}. [${r.title}](${r.url})${flag}`
  }).join('\\n')
  const tail = blocked.length > 0 ? `\\n\\n❌ 另有 ${blocked.length} 篇未能归档(取不到产物或建档失败),下次心跳会自动重试。` : ''
  await agent(
    `发飞书通知:
lark-cli im +messages-send --as bot --user-id ${OPEN_ID} --markdown "**📋 当日会议纪要已生成(${discovery.date},${ok.length}/${results.length} 篇归档)**\\n\\n${lines}${tail}"`,
    { phase: 'Notify' }
  )
} else {
  log(`本次无成功归档(${blocked.length} 篇 BLOCKED,下次心跳重试),静默不通知。`)
}

const RESULT = {
  date: discovery.date, dayNode: DAY_NODE, minScore: MIN_SCORE,
  dryRun: DRY_RUN || undefined,
  total: results.length, count: ok.length,
  outputTokens: budget.spent(),   // 本次 workflow 输出 token 总量(运营成本趋势用)
  docs: results.map(r => ({ token:r.token, title:r.title, url:r.url, score:r.score, verdict:r.verdict, gaps:(r.gaps||[]).map(g=>g.desc) })),
  blocked: blocked.map(r => ({ token:r.token, title:r.title, reason:(r.gaps&&r.gaps[0]&&r.gaps[0].desc)||'unknown' })),
}
await persist(RESULT)
return RESULT
