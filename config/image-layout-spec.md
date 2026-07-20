# 纪要配图 · 图文分栏排版规格（image-layout-spec）

给 Publish agent 用：决定给某议题/段落配图后，按本规格把「文字 + 图」排成左右分栏
（观感参考飞书妙记 AI 总结画板：左栏叙述文字，右栏示意图 + 图注）。
图是通栏全景图、或对应文字太少撑不起一栏时，退化为简单插入（media-insert 后不再动）即可。

## 原则

- 原有内容块**只移动、不重写**。唯一例外：配图所覆盖的文字段落可**适当精简**——
  图和 caption 已表达清楚的细节（分工关系、流程走向、结构组成等）从文字里收敛掉，
  只留判断与结论；精简用 `block_replace` 完成，不得改变事实、不得删掉图未覆盖的信息。
- 图片块**整体移动**，图片 token（src）与 caption 自动保留，无需重传。
- 全程失败容忍：任何一步报错就放弃分栏——文档里已有图的"简单插入态"就是可接受的最终结果，
  不要为修复排版反复折腾。

## 流程（五步，已端到端验证）

1. **插图**：cd 到图片所在目录（`--file` 只接受当前目录相对路径），
   `lark-cli docs +media-insert --as user --doc <文档url> --file ./<png> --caption "<一句图注>"`
   （默认落到文档末尾，位置无所谓，第 4 步会移走。）
2. **取 block id**：`lark-cli docs +fetch --as user --doc <文档url> --detail with-ids --format json`，
   记下三类 id：要移进左栏的段落/列表块 id、图片 `<img>` 块 id、grid 的插入锚点 id（通常是该议题的标题块）。
3. **插空 grid 骨架**（占位块的作用是提供"列内"锚点）：
   ```
   lark-cli docs +update --as user --doc <文档url> --command block_insert_after \
     --block-id <锚点id> \
     --content '<grid><column width-ratio="0.5"><p>LEFT_PLACEHOLDER</p></column><column width-ratio="0.5"><p>RIGHT_PLACEHOLDER</p></column></grid>'
   ```
   然后**重新 fetch**，拿到两个占位 `<p>` 的 block id（插入后才存在）。
4. **逐块移栏**（`--src-block-ids` 按原文顺序逗号分隔，顺序保留）：
   - 文字进左栏：`--command block_move_after --block-id <LEFT占位id> --src-block-ids <段落id1,段落id2,...>`
   - 图片进右栏：`--command block_move_after --block-id <RIGHT占位id> --src-block-ids <img块id>`
5. **删占位**：`--command block_delete --block-id "<LEFT占位id>,<RIGHT占位id>"`。
   （可选）随后对左栏文字做适当精简：`--command block_replace --block-id <段落id> --content '<p>精简后文字</p>'`。

## 注意

- `width-ratio` 服务端可能归一化为 0.5/0.5，不必纠结精确比例。
- 写操作后旧 block id 可能失效：每一步依赖 id 之前，重新 fetch 一次最稳。
- 一篇纪要最多 1–2 处分栏，别把全文都排成栏；「一、一句话结论」的画板不要动。
