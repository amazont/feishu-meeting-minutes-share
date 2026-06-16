# ====== 每日会议纪要自动化 · 个人配置 ======
# 朋友只需修改这个文件里的值,其它脚本都不用动。
# 改完后用 `source` 不需要,wrapper 会自动读取本文件。

# 1) 知识库「我的文档库」根节点 token
#    获取:打开你的飞书知识库目标节点,URL 形如 https://xxx.feishu.cn/wiki/<这一段就是>
WIKI_ROOT="在此填入你的_wiki_node_token"

# 2) 知识库 space_id
#    获取:运行 `lark-cli wiki +space-list --format json`,找到「我的文档库」的 space_id
SPACE_ID="在此填入你的_space_id"

# 3) 你的飞书 open_id(接收通知)
#    获取:运行 `lark-cli contact +user-get --user-id me --format json` 或看授权信息
OPEN_ID="在此填入你的_open_id_ou_xxx"

# 4) 你的飞书域名(妙记/文档链接用)
#    就是你飞书的网址前缀,如 https://xxx.feishu.cn
MINUTE_HOST="https://你的域名.feishu.cn"

# 5) 本地归档根目录(按天分子目录存纪要副本)
BASE_DIR="$HOME/Documents/会议纪要"

# 6) workflow 脚本要放到的位置(CC 命名 workflow 目录,一般不用改)
WORKFLOW_DIR="$HOME/.claude/workflows"
