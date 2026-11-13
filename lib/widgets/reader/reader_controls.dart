// Ported from Wenku8_Flutter@ebcd7f1, lib/pages.dart:_readerBottomControls /
// _readerAction and lib/reader_chrome.dart. Six reader actions and an optional
// AI action use the upstream dock; progress scrubs within the current chapter.
// fqapp's listening/video controls remain separate, above this dock.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import '../wenku/wenku_ui.dart';
import 'reader_chapter_progress.dart';
import 'reader_chrome.dart';
import 'reader_theme.dart';

class ReaderControls extends StatelessWidget {
  const ReaderControls({
    super.key,
    required this.preferences,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.fraction,
    required this.animation,
    required this.previewing,
    required this.onPrevious,
    required this.onNext,
    required this.onPreview,
    required this.onCommitted,
    required this.onPreviewChanged,
    required this.onDirectory,
    required this.onBookmarks,
    required this.onAppearance,
    required this.onOperations,
    required this.onFind,
    required this.onNight,
    this.onAi,
    this.onDownload,
    this.aiLabel = 'AI 校对',
    this.novelOnly = false,
  });

  final ReaderPreferences preferences;
  final int chapterIndex;
  final String chapterTitle;
  final double? fraction;
  final Animation<double> animation;
  final bool previewing;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommitted;
  final ValueChanged<bool> onPreviewChanged;
  final VoidCallback onDirectory;
  final VoidCallback onBookmarks;
  final VoidCallback onAppearance;
  final VoidCallback onOperations;
  final VoidCallback? onFind;
  final VoidCallback onNight;
  final VoidCallback? onAi;
  final VoidCallback? onDownload;
  final String aiLabel;
  final bool novelOnly;

  @override
  Widget build(BuildContext context) {
    final preset = preferences.themePreset;
    final labels = [
      '目录',
      '书签',
      novelOnly ? '阅读设置' : '外观',
      onDownload == null ? '操作' : '下载',
      '查找',
      if (onAi != null) aiLabel,
      preset.isDark ? '日间' : '夜读',
    ];
    var minActionWidth = 48.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > minActionWidth) minActionWidth = painter.width;
      painter.dispose();
    }
    final dockAnimation = animation.drive(
      CurveTween(curve: const Interval(0, .90)),
    );
    final progressAnimation = animation.drive(
      CurveTween(curve: const Interval(.10, 1)),
    );
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ReaderChromeLayer(
                    animation: progressAnimation,
                    interactionThreshold: 0,
                    maintainSize: true,
                    slide: const Offset(0, 1.28),
                    curve: WenkuMotion.settle,
                    scaleFrom: .90,
                    clip: false,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: DockLayout.widthFor(5) - 32,
                      ),
                      child: ReaderChapterProgress(
                        key: ValueKey((
                          'reader-chapter-progress',
                          chapterIndex,
                        )),
                        preset: preset,
                        fraction: fraction,
                        chapterLabel: chapterTitle,
                        onPreview: onPreview,
                        onCommitted: onCommitted,
                        onPreviewChanged: onPreviewChanged,
                        onPrevious: onPrevious,
                        onNext: onNext,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Visibility(
                    visible: !previewing,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: ReaderChromeLayer(
                      animation: dockAnimation,
                      interactionThreshold: 0,
                      maintainSize: true,
                      slide: const Offset(0, 1),
                      curve: WenkuMotion.settle,
                      scaleFrom: .96,
                      clip: false,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: DockLayout.widthFor(onAi == null ? 6 : 7),
                        ),
                        child: LiquidGlass(
                          key: const ValueKey('reader-liquid-dock'),
                          radius: DockLayout.heightOf(context) / 2,
                          thickness: 16,
                          tintColor: preset.panelColor,
                          padding: const EdgeInsets.symmetric(
                            horizontal: DockLayout.horizontalInset,
                          ),
                          child: SizedBox(
                            height: DockLayout.heightOf(context),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final requiredWidth =
                                    minActionWidth * labels.length;
                                final scrolls =
                                    constraints.maxWidth < requiredWidth;
                                return Semantics(
                                  label: scrolls ? '阅读操作，可横向滚动' : '阅读操作',
                                  container: true,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SizedBox(
                                      width: scrolls
                                          ? requiredWidth
                                          : constraints.maxWidth,
                                      child: Row(
                                        children: [
                                          _DockAction(
                                            key: const ValueKey(
                                              'reader-catalogue-entry',
                                            ),
                                            icon: CupertinoIcons.list_bullet,
                                            label: '目录',
                                            onPressed: onDirectory,
                                          ),
                                          _DockAction(
                                            key: const ValueKey(
                                              'reader-bookmarks-entry',
                                            ),
                                            icon: CupertinoIcons.bookmark,
                                            label: '书签',
                                            onPressed: onBookmarks,
                                          ),
                                          _DockAction(
                                            key: const ValueKey(
                                              'reader-settings',
                                            ),
                                            icon: CupertinoIcons.textformat,
                                            label: novelOnly ? '阅读设置' : '外观',
                                            onPressed: onAppearance,
                                          ),
                                          _DockAction(
                                            key: ValueKey(
                                              onDownload == null
                                                  ? 'reader-operations-entry'
                                                  : 'reader-download-entry',
                                            ),
                                            icon: onDownload == null
                                                ? CupertinoIcons
                                                      .slider_horizontal_3
                                                : CupertinoIcons
                                                      .tray_arrow_down,
                                            label: onDownload == null
                                                ? '操作'
                                                : '下载',
                                            onPressed:
                                                onDownload ?? onOperations,
                                          ),
                                          _DockAction(
                                            key: const ValueKey(
                                              'reader-find-entry',
                                            ),
                                            icon: CupertinoIcons.search,
                                            label: '查找',
                                            onPressed: onFind,
                                          ),
                                          if (onAi != null)
                                            _DockAction(
                                              key: const ValueKey('reader-ai'),
                                              icon: CupertinoIcons.sparkles,
                                              label: aiLabel,
                                              onPressed: onAi,
                                            ),
                                          _DockAction(
                                            key: const ValueKey(
                                              'reader-night-entry',
                                            ),
                                            icon: preset.isDark
                                                ? CupertinoIcons.sun_max
                                                : CupertinoIcons.moon,
                                            label: preset.isDark ? '日间' : '夜读',
                                            onPressed: onNight,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: JellyTapSurface(
        onTap: onPressed,
        child: SizedBox(
          height: DockLayout.heightOf(context),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ArchiveIcon(
                  icon,
                  size: DockLayout.iconSize,
                  color: onPressed == null
                      ? Theme.of(context).disabledColor
                      : null,
                ),
                const SizedBox(height: DockLayout.labelGap),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        color: onPressed == null
                            ? Theme.of(context).disabledColor
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ReaderCacheButton extends StatelessWidget {
  const ReaderCacheButton({
    super.key,
    required this.preset,
    required this.onTap,
  });
  final ReaderThemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GlassIconButton(
    key: const ValueKey('reader-cache'),
    icon: CupertinoIcons.tray_arrow_down,
    label: '缓存',
    color: preset.textColor,
    onPressed: onTap,
  );
}
