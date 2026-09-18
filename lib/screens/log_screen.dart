import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/router.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:path/path.dart' as path;

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  List<LogEntry> flutter = [];
  List<LogEntry> breez = [];
  List<LogEntry> native = [];
  List<LogEntry> rust = [];

  bool isSearching = false;
  final searchDeBouncer = DeBouncer(const Duration(milliseconds: 500));
  final searchController = SearchTagStylingTextEditingController();
  final searchFieldFocusNode = FocusNode();
  String? searchTerm;

  int selectedTab = 0;
  final pageController = PageController();
  bool isAnimatingPage = false;

  @override
  void initState() {
    postFrameCallBack(() => fetchLogs());
    super.initState();
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFieldFocusNode.dispose();
    searchDeBouncer.cancel();
    pageController.dispose();
    super.dispose();
  }

  Future<void> fetchLogs({String? file}) async {
    final logFiles = await LogManager.getRecentLogFiles();
    for (final logFile in logFiles) {
      final filePath = logFile.path;

      if (path.basename(filePath).startsWith('flutter') && (file == null || file == 'flutter')) {
        flutter = await LogManager.fetchFileLogs(filePath);
      } else if (path.basename(filePath).startsWith('breez') && (file == null || file == 'breez')) {
        breez = await LogManager.fetchFileLogs(filePath);
      } else if (Platform.isAndroid &&
          path.basename(filePath).startsWith('android') &&
          (file == null || file == 'native')) {
        native = await LogManager.fetchFileLogs(filePath);
      } else if ((Platform.isIOS || Platform.isMacOS) &&
          path.basename(filePath).startsWith('ios') &&
          (file == null || file == 'native')) {
        native = await LogManager.fetchFileLogs(filePath);
      } else if (path.basename(filePath).startsWith('rust') && (file == null || file == 'rust')) {
        try {
          rust.clear();
          final List<String> failed = [];

          const splitter = LineSplitter();
          final stream = File(filePath).openRead().map(utf8.decode);

          await for (final line in splitter.bind(stream)) {
            try {
              rust.add(LogEntry.fromRustLine(jsonDecode(line)));
            } catch (e) {
              failed.add(line);
            }
          }

          for (final line in splitter.convert(failed.join())) {
            try {
              rust.add(LogEntry.fromRustLine(jsonDecode(line)));
            } catch (_) {}
          }
        } catch (_) {}
      }
    }

    flutter.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    breez.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    native.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    rust.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    update();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            onPressed: () {
              update(() => isSearching = !isSearching);
              searchFieldFocusNode.requestFocus();
            },
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 1, child: Text('Share logs')),
              const PopupMenuItem(value: 2, child: Text('Delete logs')),
            ],
            onSelected: (value) async {
              if (value == 1) {
                final zipData = await LogManager.exportLogs();
                if (zipData != null) {
                  final savedPath = await FileSaver.instance.saveAs(
                    name: 'manna_logs_${DateFormat('yyyy_MM_dd_hh_mm').format(DateTime.now())}',
                    bytes: zipData,
                    mimeType: MimeType.zip,
                    fileExtension: 'zip',
                  );
                  if (savedPath?.isNotEmpty ?? false) ToastService.show('Logs saved successfully.');
                }
              } else if (value == 2) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Are you sure you want to delete all logs?', style: TextStyle(fontSize: 16)),
                    actions: [
                      TextButton(onPressed: () => AppRouter.pop(), child: const Text('No')),
                      TextButton(
                        onPressed: () async {
                          await LogManager.clearAllLogs();
                          flutter.clear();
                          breez.clear();
                          native.clear();
                          rust.clear();
                          update();
                          AppRouter.pop();
                        },
                        child: const Text('Yes'),
                      ),
                    ],
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          if (isSearching) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SearchBar(
                controller: searchController,
                focusNode: searchFieldFocusNode,
                onChanged: (value) {
                  searchDeBouncer.call(() => update(() => searchTerm = value.trim().toLowerCase()));
                },
                padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 16)),
                hintText: 'search...',
                leading: const Icon(Icons.search),
                trailing: [
                  Tooltip(
                    message: 'Close',
                    child: IconButton(
                      onPressed: () {
                        searchTerm = null;
                        update(() => isSearching = false);
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: CupertinoSlidingSegmentedControl(
              groupValue: selectedTab,
              onValueChanged: (val) => selectTab(val ?? 0),
              children: {
                0: buildSegment('Flutter'),
                1: buildSegment('Spark'),
                2: buildSegment('Native'),
                3: buildSegment('Rust'),
              },
              padding: const EdgeInsets.all(8),
            ),
          ),
          Expanded(
            child: PageView(
              controller: pageController,
              onPageChanged: (value) => selectTab(value),
              children: [
                Builder(
                  builder: (context) {
                    final logs = applySearch(flutter);
                    if (logs.isEmpty) {
                      return const Center(child: Text('No logs yet'));
                    }
                    return RefreshIndicator(
                      onRefresh: () => fetchLogs(file: 'flutter'),
                      child: ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) => logTile(logs[index]),
                      ),
                    );
                  },
                ),
                Builder(
                  builder: (context) {
                    final logs = applySearch(breez);
                    if (logs.isEmpty) {
                      return const Center(child: Text('No logs yet'));
                    }
                    return RefreshIndicator(
                      onRefresh: () => fetchLogs(file: 'breez'),
                      child: ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) => logTile(logs[index]),
                      ),
                    );
                  },
                ),
                Builder(
                  builder: (context) {
                    final logs = applySearch(native);
                    if (logs.isEmpty) {
                      return const Center(child: Text('No logs yet'));
                    }
                    return RefreshIndicator(
                      onRefresh: () => fetchLogs(file: 'native'),
                      child: ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) => logTile(logs[index]),
                      ),
                    );
                  },
                ),
                Builder(
                  builder: (context) {
                    final logs = applySearch(rust);
                    if (logs.isEmpty) {
                      return const Center(child: Text('No logs yet'));
                    }
                    return RefreshIndicator(
                      onRefresh: () => fetchLogs(file: 'rust'),
                      child: ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) => logTile(logs[index]),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<LogEntry> applySearch(List<LogEntry> logs) {
    if (searchTerm != null) {
      if (searchTerm!.startsWith('tag:')) {
        final tag = searchTerm!.replaceFirst('tag:', '').trim();
        if (tag.isNotEmpty) {
          return logs.where((l) => l.tag?.contains(tag) ?? false).toList();
        }
      } else if (searchTerm!.startsWith('level:') || searchTerm!.startsWith('lvl:')) {
        final level = searchTerm!.replaceFirst('level:', '').replaceFirst('lvl:', '').trim().toLowerCase();
        if (level.isNotEmpty) {
          return logs.where((l) => l.level.toLowerCase().startsWith(level)).toList();
        }
      } else {
        return logs.where((l) => l.message.toLowerCase().contains(searchTerm!)).toList();
      }
    }
    return logs;
  }

  Widget buildSegment(String name) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: FittedBox(fit: BoxFit.scaleDown, child: Text(name)),
  );

  final errorColor = Colors.red.withValues(alpha: 0.5);
  final warningColor = Colors.amber.withValues(alpha: 0.5);
  final debugColor = Colors.grey.withValues(alpha: 0.3);

  Widget logTile(LogEntry l) {
    return ListTile(
      onTap: () => AppRouter.push(LogDetailScreen(log: l)),
      leading: CircleAvatar(
        backgroundColor: switch (l.level[0].toLowerCase()) {
          'v' || 'd' => debugColor,
          'i' || 't' => null,
          'w' => warningColor,
          'e' || 'f' => errorColor,
          _ => null,
        },
        foregroundColor: context.themedColor(bright: Colors.black, dark: Colors.white),
        child: Text(l.level[0].toUpperCase()),
      ),
      title: Text(l.error ?? l.message, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        'at ${LogManager.logTimestampFormat.format(l.timestamp.toLocal())} ${l.tag?.isNotEmpty ?? false ? 'in ${l.tag}' : ''}',
      ),
      titleTextStyle: Theme.of(context).textTheme.bodyMedium,
      subtitleTextStyle: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
    );
  }

  void selectTab(int tab) async {
    if (isAnimatingPage) return;

    selectedTab = tab;
    if (selectedTab != (pageController.page?.toInt() ?? 0)) {
      isAnimatingPage = true;
      unawaited(
        pageController
            .animateToPage(selectedTab, duration: const Duration(milliseconds: 300), curve: Curves.fastOutSlowIn)
            .then((value) => isAnimatingPage = false),
      );
    }
    update();
  }
}

class LogDetailScreen extends StatelessWidget {
  const LogDetailScreen({required this.log, super.key});

  final LogEntry log;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log Data'),
        actions: [
          IconButton(
            onPressed: () => ClipboardService.setClipBoard(jsonEncode(log.toMap())),
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Level', style: TextStyle(color: Colors.grey, fontSize: 12)),
            Text(
              (log.level.length == 1
                      ? switch (log.level.toLowerCase()) {
                          'v' => 'verbose',
                          'd' => 'debug',
                          'i' => 'info',
                          't' => 'trace',
                          'w' => 'warning',
                          'e' => 'error',
                          'f' => 'fatal',
                          _ => '',
                        }
                      : log.level)
                  .toUpperCase(),
              style: TextStyle(
                color: log.level.startsWith('E') || log.level.startsWith('F')
                    ? Colors.red
                    : log.level.startsWith('W')
                    ? Colors.amber
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            ...entry('Timestamp', LogManager.logTimestampFormat.format(log.timestamp.toLocal())),
            ...entry('Message', log.message),
            ...entry('Error', log.error ?? '-'),
            ...entry('Tag', log.tag ?? '-'),
            ...entry('Stack Trace', log.stack ?? '-'),
          ],
        ),
      ),
    );
  }

  List<Widget> entry(String title, String data) {
    return [
      Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      SelectableText(data),
      const SizedBox(height: 12),
    ];
  }
}

class SearchTagStylingTextEditingController extends TextEditingController {
  static List<String> supportedTags = ['level', 'lvl', 'tag'];
  @override
  TextSpan buildTextSpan({required BuildContext context, required bool withComposing, TextStyle? style}) {
    final t = text.toLowerCase();
    final tag = supportedTags.where((tag) => t.startsWith('$tag:')).firstOrNull;

    if (tag != null) {
      return TextSpan(
        children: [
          TextSpan(
            text: '$tag:'.toUpperCase(),
            style: style?.copyWith(color: AppColors.primaryColor),
          ),
          TextSpan(text: text.replaceFirst('$tag:', ''), style: style),
        ],
      );
    }

    return super.buildTextSpan(context: context, withComposing: withComposing, style: style);
  }
}
