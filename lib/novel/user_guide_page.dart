import 'package:flutter/material.dart';

/// An in-app guide; opening or reading it does not change the user's data.
class NovelUserGuidePage extends StatelessWidget {
  const NovelUserGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);

    return Scaffold(
      appBar: AppBar(title: const Text('使用说明')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              key: const ValueKey('user-guide-scroll'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('快速开始', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      const _GuideParagraph('1. 在书城搜索书名或作者，打开书籍详情。'),
                      const _GuideParagraph('2. 点“阅读本书”，阅读时点屏幕中央查看目录和设置。'),
                      const _GuideParagraph('3. 点“加入书架”，以后可从书架继续阅读。'),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('按主题查看', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('点按主题展开详细操作与常见问题。', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 8),
                for (final section in _sections)
                  ExpansionTile(
                    key: PageStorageKey<String>('user-guide-${section.id}'),
                    title: Text(section.title),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    expansionAnimationStyle: reduceMotion
                        ? AnimationStyle.noAnimation
                        : null,
                    children: [
                      for (final paragraph in section.paragraphs)
                        _GuideParagraph(paragraph),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GuideParagraph extends StatelessWidget {
  const _GuideParagraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55),
    ),
  );
}

class _GuideSection {
  const _GuideSection(this.id, this.title, this.paragraphs);

  final String id;
  final String title;
  final List<String> paragraphs;
}

const _sections = <_GuideSection>[
  _GuideSection('find', '找书与推荐', [
    '在书城搜索书名或作者，也可浏览题材、评分和连载状态。打开感兴趣的书，可查看简介、目录和书评。',
    '模糊、拼音全拼和首字母匹配会查找本机书架、阅读历史及已浏览书目；未浏览的作品仍可通过联网搜索查找。',
    '题材可联网查找；评分等筛选和排序针对已加载结果。条件较严格时可能需要等待联网加载更多；没有匹配时可放宽条件。',
    '个性化推荐参考本机书架和阅读题材，可在“设置 → 个性化推荐”关闭。',
  ]),
  _GuideSection('shelf', '书架与阅读进度', [
    '在书籍详情或阅读上栏点“加入书架”。回到书架点书名即可继续阅读。书架右上角的“书架管理”可管理分组或多选书籍。',
    '点书籍旁的“书籍操作”，可设置阅读状态、置顶、移动分组和养肥目标。删除分组会将书移到未分组；移出书架会保留阅读记录、笔记和下载。',
    '养肥度是当前位置之后待看章节数与目标的比较，默认目标 50 章，可在书籍操作中调整。目录或当前章节身份无法确认时不会冒充已养肥；它不代表下载比例。',
    '全书进度由当前目录和章内位置估算，新增章节后比例可能变化。',
  ]),
  _GuideSection('reader', '阅读、标注与段评', [
    '阅读时点屏幕中央显示控制栏，可打开目录、切换章节和调整阅读设置。全局排版在“设置 → 阅读设置”，单本书可在阅读菜单中选择“本书阅读配置”。',
    '长按正文并调整选区，可复制、查词、翻译、划线、添加书签或笔记；选词工具栏可左右滑动，查看更多操作。已保存的标注可在书签与标注中回看。选择查词或翻译服务后，选中文字会交给所选网站或应用。',
    '在线书籍有段评时，可点正文旁的评论入口查看段评和回复；阅读菜单也提供“段落评论”及显示开关。段评和回复目前只可浏览，不能发表。',
  ]),
  _GuideSection('appearance', '外观与阅读配置', [
    '在“设置 → 应用外观”选择跟随系统、日间或夜间；“主题颜色”提供朱砂、松绿、靛青、湖蓝、藤紫和琥珀。这里调整的是书城、书架和设置的外观。',
    '正文背景与应用外观分别设置。在“设置 → 阅读设置”或阅读页中可调整字体、字号、行距、背景以及分页或滚动等阅读方式。',
    '在“设置 → 阅读配置方案”可从当前全局排版新建命名方案。阅读页更多操作中的“本书阅读配置”可应用方案或单独调整字号、行距和翻页方式；其他设置仍跟随全局。',
  ]),
  _GuideSection('auto-read', '自动阅读', [
    '在阅读页点屏幕中央，再点上方更多操作，选择“自动阅读”；调整前进间隔后点“开始自动阅读”。分页模式自动翻页，滚动模式按间隔向下滚动。',
    '点击或拖动正文、打开评论或设置、选词、离开阅读页、应用进入后台或锁屏时会暂停。暂停后可再次进入自动阅读手动开始；到全书末尾会停止。',
  ]),
  _GuideSection('downloads', '下载与追更', [
    '在书籍详情点“下载”，或在阅读页的更多操作中选“下载与追更”。可从当前阅读位置选择章数、指定起止章节或选择全本。',
    '下载任务在前台按顺序处理。暂停或移除队列任务不会删除已下载章节；可在“设置 → 离线下载”或书架的“离线书籍”中查看和管理。',
    '自动下载新章节会在打开应用或回到前台时检查已下载书籍，默认仅使用 Wi-Fi，只补新增章节，不会补齐以前未下载的旧章节。可在下载设置中调整。',
    '“立即检查更新”会使用当前网络。离线时可阅读已下载或仍在本机缓存中的章节；未保存的章节仍需联网。',
  ]),
  _GuideSection('local', '导入本地小说', [
    '进入“设置 → 本地小说”，点“选择小说文件”，或在书架管理中选择“导入本地小说”。支持 32 MB 以内的 TXT 和 EPUB。',
    'TXT 支持 UTF-8、带标记的 UTF-16 和 GB18030；EPUB 按文本章节阅读。本地书保存在本机，不通过小说接口获取正文。',
    '阅读备份不包含本地原书文件。换机时请另存原文件并在新设备重新导入同一文件，以便接回标注。尽量保留原文件和文件名；修改正文、作者或封面等可能导致无法接回原标注。',
  ]),
  _GuideSection('reports', '阅读报告与休息提醒', [
    '在“设置 → 阅读报告”可切换月报和年报，点中间日期选择月份或年份，也可用左右箭头切换周期、查看全部周记录。',
    '统计只记录阅读器在前台的时间，可能包含静置时间，不代表一定读完；只显示本机已记录的数据，最多保留 730 个有记录的日期。',
    '评论、设置、后台和锁屏期间会暂停计时。休息提醒默认关闭，可在设置或阅读菜单中开启；达到设置的前台累计时间时会提醒并暂停自动翻页。',
  ]),
  _GuideSection('backup', '备份与恢复', [
    '在“设置 → 备份与恢复阅读数据”导出备份文件，保存到安全的位置。可选择同时备份可迁移的阅读偏好与新功能数据。',
    '备份包含书架、分组、进度、书签、划线和笔记；不包含下载正文、字体文件、本地 TXT/EPUB 原书或账号和 API 凭据。',
    '恢复时先选择文件并预览。默认补充缺失记录并保留本机已有进度和笔记；只有勾选指定书籍，才用备份覆盖该书进度。',
    '本机快照位于应用内，卸载或清除应用数据后也会删除；换机请导出备份，并另存本地原书文件。',
  ]),
  _GuideSection('ai', 'AI 小说问答', [
    '小说 AI 默认关闭。需要使用时，进入“设置 → AI 小说问答”，自行填写兼容 OpenAI 的服务地址、API Key 和模型，启用并保存。示例地址为 https://api.deepseek.com，模型为 deepseek-chat。',
    'API Key 保存在设备安全存储中，不进入阅读备份；可在设置中选择“清除密钥并关闭”。',
    '阅读中点 AI 悬浮球或从更多操作进入“小说 AI 问答”。悬浮球可拖动，也可在更多操作中隐藏、显示或移到另一侧。',
    '发送问题会把书名、作者、当前章节等本书资料发给所配置的服务，询问作品介绍时才附带简介；后续请求还会携带本次面板中的近期问答。设置发生变化会清空对话。正文默认不发送。',
    '询问具体人物或剧情时，可在问答面板点“启用已读原文检索”并确认，或在服务设置中选择“发送已读正文和相关摘录”。应用会检索已确认读过的章节和当前已显示正文，并向服务发送相关片段；未读章节不会参与检索。',
    '旧进度无法证明此前每章都读过；只有确认全部读过，才使用“补录已读前文”。它只补录当前章之前可取得的本地正文；缺失时可先下载后再次补录。已读片段在本机加密保存，不进入阅读备份。已读范围或本机正文不完整时，回答可能缺少依据。回答下的“参考原文”可展开本次发送的章节与片段。',
    '连续追问可以用“他为什么这样做”等短句，检索会结合本面板最近的问题。切换话题时可直接写明新人物或情节；清空会话后不会继续沿用旧问题。',
    '服务按其规则计费，连接测试也可能产生费用；测试不发送正在阅读的书籍。回答可能不准确，请结合原文判断。关闭面板、点“停止”或应用进入后台会取消正在进行的请求。',
  ]),
  _GuideSection('updates', '软件更新', [
    '进入“设置 → 软件更新”，应用从 GitHub Releases 检查新版本。发现更新后可下载并校验，再点“安装更新”。',
    '安装需要在系统安装器中确认；如系统提示，请先允许安装此来源应用，返回后再次点“安装更新”。',
    '检查或下载失败时，可确认网络能够访问 GitHub、检查存储空间，再重试。',
  ]),
  _GuideSection('faq', '常见问题', [
    '搜索不到书：检查书名或作者、放宽筛选并加载更多；本机拼音匹配不覆盖尚未浏览的全部书目。',
    '章节打不开：先检查网络并重试。离线时只能打开已经下载或缓存的章节；目录变化后可尝试刷新目录。',
    '段评没有显示：检查阅读菜单中的段评显示开关和网络；也可能该段暂无评论。加载失败时可从“段落评论”重试。',
    '换机后找不到本地书：阅读备份不含原文件，请将未修改的 TXT/EPUB 原文件重新导入。',
    'AI 无法回答：检查开关、服务地址、API Key、模型、网络和服务额度，再手动重试。',
  ]),
];
