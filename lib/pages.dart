import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'database.dart';
import 'helpers.dart';
import 'models.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  void _goToCropsTab() {
    setState(() => _currentIndex = 1);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      FarmDashboardPage(onViewCrops: _goToCropsTab),
      const PlotHistoryPage(),
      const ChemicalsPage(),
      const MorePage(),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.grass_outlined),
            selectedIcon: Icon(Icons.grass),
            label: 'Crops',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Chemicals',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz_outlined),
            selectedIcon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }
}

// ============================================================
// FARM DASHBOARD (new FarmBook Home tab)
// ============================================================

/// Shows a plot picker (bottom sheet) and returns the chosen plot, or null
/// if the user cancelled. If there is exactly one plot, it is returned
/// immediately without showing a picker.
Future<Map<String, dynamic>?> _fbPickPlot(
  BuildContext context,
  List<Map<String, dynamic>> plots, {
  String title = 'Choose a crop / plot',
}) async {
  if (plots.isEmpty) return null;
  if (plots.length == 1) return plots.first;

  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: plots.length,
              itemBuilder: (_, i) {
                final plot = plots[i];
                return ListTile(
                  leading: const Icon(Icons.grass),
                  title: Text(plot['title'].toString()),
                  subtitle: plot['crop_variety'].toString().isEmpty
                      ? null
                      : Text(plot['crop_variety'].toString()),
                  onTap: () => Navigator.pop(sheetContext, plot),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// If there are no plots yet, shows a snackbar prompting the user to add
/// one first. Returns true if it's safe to continue (a plot exists).
Future<bool> _fbRequirePlots(
  BuildContext context,
  List<Map<String, dynamic>> plots,
  VoidCallback onAddCropRequested,
) async {
  if (plots.isNotEmpty) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Add a crop / plot first.')),
  );
  onAddCropRequested();
  return false;
}

class FarmDashboardPage extends StatefulWidget {
  const FarmDashboardPage({super.key, required this.onViewCrops});

  /// Called when the user wants to jump to the Crops tab (e.g. "View all"
  /// or when there are no crops yet).
  final VoidCallback onViewCrops;

  @override
  State<FarmDashboardPage> createState() => _FarmDashboardPageState();
}

class _FarmDashboardPageState extends State<FarmDashboardPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _plots = [];
  final Map<int, Map<String, dynamic>?> _lastSprayByPlot = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final plots = await AppDatabase.instance.getPlots();

    // Only look up "last spray" for a handful of plots shown on the
    // dashboard, to keep this screen light.
    final lastSprays = <int, Map<String, dynamic>?>{};
    for (final plot in plots.take(6)) {
      final id = plot['id'] as int;
      lastSprays[id] = await AppDatabase.instance.getLastSprayForPlot(id);
    }

    if (!mounted) return;
    setState(() {
      _plots = plots;
      _lastSprayByPlot
        ..clear()
        ..addAll(lastSprays);
      _loading = false;
    });
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning! 👋';
    if (hour < 17) return 'Good Afternoon! 👋';
    return 'Good Evening! 👋';
  }

  /// Groups plots by crop variety (falling back to the plot title when no
  /// crop variety is set) so the dashboard can show one card per crop
  /// instead of one per individual plot.
  List<_FbCropGroup> _cropGroups() {
    final groups = <String, _FbCropGroup>{};
    for (final plot in _plots) {
      final crop = plot['crop_variety'].toString().trim();
      final key = crop.isEmpty ? plot['title'].toString() : crop;
      groups.putIfAbsent(key, () => _FbCropGroup(name: key));
      groups[key]!.plots.add(plot);
    }
    return groups.values.toList();
  }

  Future<void> _openPlot(Map<String, dynamic> plot) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlotOverviewPage(
          plotId: plot['id'] as int,
          plotTitle: plot['title'].toString(),
          plotName: plot['plot_name'].toString(),
          cropVariety: plot['crop_variety'].toString(),
        ),
      ),
    );
    await _load();
  }

  Future<void> _quickAction(String action) async {
    // Chemicals is not tied to a specific plot, so it skips the plot picker.
    if (action == 'chemicals') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChemicalsPage()),
      );
      await _load();
      return;
    }

    final ok = await _fbRequirePlots(context, _plots, widget.onViewCrops);
    if (!ok || !mounted) return;
    final plot = await _fbPickPlot(context, _plots);
    if (plot == null || !mounted) return;

    final id = plot['id'] as int;
    final title = plot['title'].toString();
    final name = plot['plot_name'].toString();
    final crop = plot['crop_variety'].toString();

    Widget page;
    switch (action) {
      case 'expense':
        page = OtherExpensesPage(plotId: id, plotTitle: title);
        break;
      case 'earning':
        page = EarningsPage(plotId: id, plotTitle: title);
        break;
      case 'labour':
        page = LabourPage(plotId: id, plotTitle: title);
        break;
      case 'drip':
        page = PlotSpraysPage(
          plotId: id,
          plotTitle: title,
          plotName: name,
          cropVariety: crop,
          initialTab: 1,
        );
        break;
      case 'spray':
      default:
        page = PlotSpraysPage(
          plotId: id,
          plotTitle: title,
          plotName: name,
          cropVariety: crop,
        );
    }

    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final groups = _cropGroups();

    return Scaffold(
      appBar: AppBar(title: const Text('FarmBook')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            // 1) Simple, personal greeting — no promotional copy.
            Text(
              _greeting(),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),

            // 2) Quick actions — six farm-focused shortcuts, always visible.
            const Text(
              'Quick actions',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _FbQuickAction(
                    icon: Icons.science,
                    label: 'Spray',
                    onTap: () => _quickAction('spray'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FbQuickAction(
                    icon: Icons.opacity,
                    label: 'Drip',
                    onTap: () => _quickAction('drip'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FbQuickAction(
                    icon: Icons.groups,
                    label: 'Labour',
                    onTap: () => _quickAction('labour'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _FbQuickAction(
                    icon: Icons.local_pharmacy,
                    label: 'Chemicals',
                    onTap: () => _quickAction('chemicals'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FbQuickAction(
                    icon: Icons.receipt_long,
                    label: 'Expense',
                    onTap: () => _quickAction('expense'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FbQuickAction(
                    icon: Icons.payments,
                    label: 'Earnings',
                    onTap: () => _quickAction('earning'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 3) Recent crops — simple and compact, no financial dashboards.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Recent crops',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: widget.onViewCrops,
                  child: const Text('View all'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (groups.isEmpty)
              _FbEmptyCrops(onAddCrop: widget.onViewCrops)
            else ...[
              for (final group in groups.take(3))
                _FbCropCard(
                  group: group,
                  lastSpray: _lastSprayByPlot[group.plots.first['id'] as int],
                  onTap: () => _openPlot(group.plots.first),
                ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: widget.onViewCrops,
                icon: const Icon(Icons.add),
                label: const Text('Add crop / plot'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FbCropGroup {
  _FbCropGroup({required this.name});
  final String name;
  final List<Map<String, dynamic>> plots = [];
}

class _FbEmptyCrops extends StatelessWidget {
  const _FbEmptyCrops({required this.onAddCrop});
  final VoidCallback onAddCrop;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.eco_outlined, size: 40, color: Colors.grey),
            const SizedBox(height: 10),
            const Text(
              'No crops yet',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Add your first crop / plot to start tracking sprays, expenses and earnings.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onAddCrop,
              icon: const Icon(Icons.add),
              label: const Text('Add crop / plot'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FbCropCard extends StatelessWidget {
  const _FbCropCard({
    required this.group,
    required this.lastSpray,
    required this.onTap,
  });

  final _FbCropGroup group;
  final Map<String, dynamic>? lastSpray;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final plotCount = group.plots.length;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Color(0xFFE8F5E9),
                    child: Icon(Icons.grass, color: Color(0xFF2E7D32)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          plotCount == 1 ? '1 plot' : '$plotCount plots',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text('🌱 Growing', style: TextStyle(color: Color(0xFF2E7D32))),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      lastSpray == null
                          ? '🧪 No sprays recorded yet'
                          : '🧪 Last spray: ${formatDate(DateTime.parse(lastSpray!['spray_date'].toString()))}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FbQuickAction extends StatelessWidget {
  const _FbQuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(icon, color: const Color(0xFF2E7D32)),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}


// ============================================================
// MORE PAGE
// ============================================================

class MorePage extends StatefulWidget {
  const MorePage({super.key});

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  Future<void> _openPerPlotPage(String label, Widget Function(Map<String, dynamic>) builder) async {
    final plots = await AppDatabase.instance.getPlots();
    if (!mounted) return;
    if (plots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Add a crop / plot first to use $label.')),
      );
      return;
    }
    final plot = await _fbPickPlot(context, plots, title: 'Choose a crop / plot');
    if (plot == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => builder(plot)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const Icon(Icons.payments_outlined),
            title: const Text('Earnings'),
            subtitle: const Text('Record what you sold from a crop.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openPerPlotPage(
              'Earnings',
              (plot) => EarningsPage(
                plotId: plot['id'] as int,
                plotTitle: plot['title'].toString(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Expenses'),
            subtitle: const Text('Other farm expenses by crop / plot.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openPerPlotPage(
              'Expenses',
              (plot) => OtherExpensesPage(
                plotId: plot['id'] as int,
                plotTitle: plot['title'].toString(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('Labour'),
            subtitle: const Text('Track workers, days and wages.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openPerPlotPage(
              'Labour',
              (plot) => LabourPage(
                plotId: plot['id'] as int,
                plotTitle: plot['title'].toString(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.local_pharmacy_outlined),
            title: const Text('Pesticide Usage'),
            subtitle: const Text('See pesticide use by crop and year from Spray records.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PesticideUsagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('Reports'),
            subtitle: const Text('Farm-wide totals and profit.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FarmOverviewPage()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Backup & Restore'),
            subtitle: const Text('Save or restore your farm data.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BackupRestorePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  bool _busy = false;

  Future<void> _exportHistory() async {
    setState(() => _busy = true);
    try {
      final payload = await AppDatabase.instance.exportHistory();
      final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
      final fileName = 'FarmBook_history_${DateTime.now().millisecondsSinceEpoch}.json';
      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Backup FarmBook Data',
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null) return;
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], text: 'FarmBook backup');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importHistory() async {
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: false,
      );
      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;
      final text = await File(path).readAsString();
      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid FarmBook backup.');
      }
      if (decoded['format']?.toString() != 'FarmBook plot backup' &&
          decoded['format']?.toString() != 'FarmBook spray history backup' &&
          decoded['format']?.toString() != 'SprayBook spray history backup') {
        throw const FormatException('This file is not a FarmBook backup.');
      }

      if (!mounted) return;
      final shouldRestore = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Restore farm data?'),
          content: const Text(
            'The backup will be added to your existing data. '
            'Existing data will not be deleted. Exact duplicate records '
            'will be skipped.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (shouldRestore != true) return;

      final counts = await AppDatabase.instance.restoreHistory(decoded);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restore complete: ${counts['plots_added'] ?? 0} plots, '
            '${counts['sprays_added'] ?? 0} sprays, ${counts['drips_added'] ?? 0} drips, '
            '${counts['labour_added'] ?? 0} labour, ${counts['other_added'] ?? 0} expenses, '
            '${counts['earnings_added'] ?? 0} earnings added'
            '${(counts['skipped'] ?? 0) == 0 ? '' : ', ${counts['skipped']} skipped'}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Your farm data stays on this phone. Use backup to save a copy, '
            'or restore to bring data back from a previous backup file.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _exportHistory,
            icon: const Icon(Icons.upload_file),
            label: const Text('Backup FarmBook data'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _importHistory,
            icon: const Icon(Icons.download),
            label: const Text('Restore from backup'),
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// DASHBOARD
// ============================================================

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FarmBook'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(
            Icons.agriculture,
            size: 80,
            color: Color(0xFF0D47A1),
          ),
          const SizedBox(height: 12),
          const Text(
            'FarmBook',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0D47A1),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Spray records, chemical prices and costs stored locally on your phone.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 30),
          _DashboardCard(
            icon: Icons.history,
            title: 'Spray History',
            subtitle: 'Manage plots, crops and spray records.',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PlotHistoryPage(
                    standalone: true,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          _DashboardCard(
            icon: Icons.science,
            title: 'Chemical Database',
            subtitle: 'Add, edit or delete chemicals and prices.',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ChemicalsPage(
                    standalone: true,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFE3F2FD),
          child: Icon(
            icon,
            color: const Color(0xFF0D47A1),
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D47A1),
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(subtitle),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}


// ============================================================
// CHEMICALS PAGE
// ============================================================

class ChemicalsPage extends StatefulWidget {
  const ChemicalsPage({
    super.key,
    this.standalone = false,
  });

  final bool standalone;

  @override
  State<ChemicalsPage> createState() => _ChemicalsPageState();
}

class _ChemicalsPageState extends State<ChemicalsPage> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _chemicals = [];
  List<Map<String, dynamic>> _filteredChemicals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterChemicals);
    _loadChemicals();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadChemicals() async {
    try {
      final chemicals = await AppDatabase.instance.getChemicals();
      if (!mounted) return;
      setState(() {
        _chemicals = chemicals;
        _filteredChemicals = chemicals;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load chemicals: $e')),
      );
    }
  }

  void _filterChemicals() {
    final query = _searchController.text.trim().toLowerCase();
    if (!mounted) return;

    setState(() {
      _filteredChemicals = query.isEmpty
          ? List.of(_chemicals)
          : _chemicals.where((chemical) {
              final name = chemical['name'].toString().toLowerCase();
              final unit = chemical['unit']?.toString().toLowerCase() ?? '';
              return name.contains(query) || unit.contains(query);
            }).toList();
    });
  }

  Future<void> _showChemicalDialog({
    Map<String, dynamic>? chemical,
  }) async {
    final nameController = TextEditingController(
      text: chemical == null ? '' : chemical['name'].toString(),
    );
    final priceController = TextEditingController(
      text: chemical == null ||
              ((chemical['price'] as num?)?.toDouble() ?? 0) == 0
          ? ''
          : formatNumber((chemical['price'] as num).toDouble()),
    );
    final isEditing = chemical != null;
    String selectedUnit = chemical?['unit']?.toString() ?? '';
    String packageSummary = '';

    Future<void> openPriceCalculator(
      BuildContext dialogContext,
      void Function(void Function()) refresh,
    ) async {
      if (selectedUnit.isEmpty) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text('Select a unit first to use the price calculator.'),
          ),
        );
        return;
      }

      final packageSizeController = TextEditingController();
      final packagePriceController = TextEditingController();

      await showDialog<void>(
        context: dialogContext,
        builder: (calculatorContext) {
          return AlertDialog(
            title: const Text('Price calculator'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: packageSizeController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Package size ($selectedUnit)',
                    hintText: selectedUnit == 'ml'
                        ? 'Example: 500'
                        : selectedUnit == 'gram'
                            ? 'Example: 500'
                            : 'Example: 1',
                    prefixIcon: const Icon(Icons.inventory_2_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: packagePriceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Package price (₹)',
                    hintText: 'Example: 325',
                    prefixIcon: Icon(Icons.currency_rupee),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(calculatorContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final size = double.tryParse(
                    packageSizeController.text.trim(),
                  );
                  final packagePrice = double.tryParse(
                    packagePriceController.text.trim(),
                  );

                  if (size == null || size <= 0 ||
                      packagePrice == null || packagePrice < 0) {
                    ScaffoldMessenger.of(calculatorContext).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Enter a valid package size and package price.',
                        ),
                      ),
                    );
                    return;
                  }

                  final calculated = packagePrice / size;
                  priceController.text = formatNumber(calculated);
                  packageSummary =
                      '${formatNumber(size)} $selectedUnit for ₹${formatNumber(packagePrice)} → '
                      '₹${formatNumber(calculated)} per $selectedUnit';
                  refresh(() {});
                  Navigator.pop(calculatorContext);
                },
                child: const Text('Calculate'),
              ),
            ],
          );
        },
      );

      packageSizeController.dispose();
      packagePriceController.dispose();
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, refresh) {
            return AlertDialog(
              title: Text(isEditing ? 'Edit chemical' : 'Add chemical'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Chemical name *',
                        prefixIcon: Icon(Icons.science),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: priceController,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Price per unit (₹)',
                              hintText: 'Optional',
                              prefixIcon: Icon(Icons.currency_rupee),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 88,
                          child: DropdownButtonFormField<String>(
                            value: selectedUnit.isEmpty ? null : selectedUnit,
                            decoration: const InputDecoration(
                              labelText: 'Unit *',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'ml',
                                child: Text('ml'),
                              ),
                              DropdownMenuItem(
                                value: 'L',
                                child: Text('L'),
                              ),
                              DropdownMenuItem(
                                value: 'gram',
                                child: Text('gram'),
                              ),
                              DropdownMenuItem(
                                value: 'kg',
                                child: Text('kg'),
                              ),
                            ],
                            onChanged: (value) {
                              refresh(() {
                                selectedUnit = value ?? '';
                                if (selectedUnit.isEmpty) {
                                  packageSummary = '';
                                }
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Unit is used by Spray and Drip. In Drip, ml/L automatically use L/acre, while gram/kg automatically use kg/acre.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 14),
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => openPriceCalculator(dialogContext, refresh),
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Price Calculator (optional)',
                          prefixIcon: Icon(Icons.calculate_outlined),
                          suffixIcon: Icon(Icons.chevron_right),
                        ),
                        child: packageSummary.isEmpty
                            ? const Text(
                                'Tap to enter package size and price',
                                style: TextStyle(color: Colors.grey),
                              )
                            : Text(
                                packageSummary,
                                style: const TextStyle(
                                  color: Color(0xFF2E7D32),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    final priceText = priceController.text.trim();
                    final price = priceText.isEmpty
                        ? 0.0
                        : double.tryParse(priceText);

                    if (name.isEmpty || price == null || price < 0 || selectedUnit.isEmpty) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text('Enter a valid chemical name, price and unit.'),
                        ),
                      );
                      return;
                    }

                    final duplicate =
                        await AppDatabase.instance.chemicalNameExists(
                      name,
                      excludeId: isEditing ? chemical['id'] as int : null,
                    );
                    if (!dialogContext.mounted) return;
                    if (duplicate) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Chemical already exists. Use a different name.',
                          ),
                        ),
                      );
                      return;
                    }

                    try {
                      if (isEditing) {
                        await AppDatabase.instance.updateChemical(
                          id: chemical['id'] as int,
                          name: name,
                          price: price,
                          unit: selectedUnit,
                        );
                      } else {
                        await AppDatabase.instance.addChemical(
                          name: name,
                          price: price,
                          unit: selectedUnit,
                        );
                      }
                    } on StateError {
                      if (!dialogContext.mounted) return;
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Chemical already exists. Use a different name.',
                          ),
                        ),
                      );
                      return;
                    }

                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    if (!mounted) return;
                    await _loadChemicals();
                  },
                  child: Text(isEditing ? 'Save' : 'Add'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    priceController.dispose();
  }

  Future<void> _deleteChemical(Map<String, dynamic> chemical) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chemical?'),
          content: Text(
            'Delete "${chemical['name']}" from the current chemical database?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;

    await AppDatabase.instance.deleteChemical(chemical['id'] as int);
    await _loadChemicals();
  }

  Future<void> _exportChemicals() async {
    try {
      final chemicals = await AppDatabase.instance.getChemicals();
      final payload = {
        'format': 'FarmBook chemical database',
        'version': 2,
        'exported_at': DateTime.now().toIso8601String(),
        'chemicals': chemicals
            .map(
              (c) => {
                'name': c['name'].toString(),
                'price_per_unit': (c['price'] as num).toDouble(),
                'unit': c['unit']?.toString() ?? '',
              },
            )
            .toList(),
      };

      final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
      final fileName =
          'FarmBook_chemicals_${DateTime.now().millisecondsSinceEpoch}.json';

      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Chemical Database',
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null) return;

      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(path)],
        text: 'FarmBook chemical database',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Chemical export failed: $e')),
      );
    }
  }

  Future<void> _importChemicals() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: false,
      );

      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;
      final text = await File(path).readAsString();
      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid FarmBook JSON file.');
      }

      final rawChemicals = decoded['chemicals'];
      if (rawChemicals is! List) {
        throw const FormatException('No chemicals were found in the file.');
      }

      int added = 0;
      int updated = 0;
      int skipped = 0;

      for (final item in rawChemicals) {
        if (item is! Map) {
          skipped++;
          continue;
        }

        final name = item['name']?.toString().trim() ?? '';
        final priceValue = item['price_per_unit'] ?? item['price'];
        final price = priceValue == null || priceValue.toString().trim().isEmpty
            ? 0.0
            : priceValue is num
                ? priceValue.toDouble()
                : double.tryParse(priceValue.toString());
        final importedUnit = item['unit']?.toString().trim() ?? '';
        final unit = const ['ml', 'L', 'gram', 'kg'].contains(importedUnit)
            ? importedUnit
            : '';

        if (name.isEmpty || price == null || price < 0) {
          skipped++;
          continue;
        }

        final existing = _chemicals.where(
          (c) => c['name'].toString().trim().toLowerCase() == name.toLowerCase(),
        );

        if (existing.isEmpty) {
          await AppDatabase.instance.addChemical(
            name: name,
            price: price,
            unit: unit,
          );
          added++;
        } else {
          await AppDatabase.instance.updateChemical(
            id: existing.first['id'] as int,
            name: existing.first['name'].toString(),
            price: price,
            unit: unit,
          );
          updated++;
        }
      }

      await _loadChemicals();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Import complete: $added added, $updated updated'
            '${skipped == 0 ? '' : ', $skipped skipped'}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Chemical import failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chemical Database'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Import or export',
            onSelected: (value) {
              if (value == 'export') {
                _exportChemicals();
              } else if (value == 'import') {
                _importChemicals();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.upload_file),
                  title: Text('Chemical Export'),
                ),
              ),
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.download),
                  title: Text('Chemical Import'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        onPressed: () => _showChemicalDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Add chemical'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _chemicals.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(30),
                    child: Text(
                      'No chemicals saved yet.\n\nTap "Add chemical" to create your local chemical database.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          labelText: 'Search chemicals',
                          hintText: 'Search by name or unit',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: _searchController.clear,
                                  icon: const Icon(Icons.clear),
                                ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _loadChemicals,
                        child: _filteredChemicals.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.all(30),
                                children: const [
                                  Center(child: Text('No matching chemicals.')),
                                ],
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(12, 6, 12, 100),
                                itemCount: _filteredChemicals.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 6),
                                itemBuilder: (context, index) {
                                  final chemical = _filteredChemicals[index];
                                  final name = chemical['name'].toString();
                                  final price = (chemical['price'] as num).toDouble();

                                  return Card(
                                    child: ListTile(
                                      leading: const CircleAvatar(
                                        backgroundColor: Color(0xFFE3F2FD),
                                        child: Icon(
                                          Icons.science,
                                          color: Color(0xFF0D47A1),
                                        ),
                                      ),
                                      title: Text(
                                        name,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Text(
                                        price > 0
                                            ? '₹${price.toStringAsFixed(2)}${chemical['unit']?.toString().isNotEmpty == true ? ' / ${chemical['unit']}' : ' per unit'}'
                                            : (chemical['unit']?.toString().isNotEmpty == true
                                                ? 'Unit: ${chemical['unit']}'
                                                : 'Unit not set'),
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        onSelected: (value) {
                                          if (value == 'edit') {
                                            _showChemicalDialog(chemical: chemical);
                                          } else if (value == 'delete') {
                                            _deleteChemical(chemical);
                                          }
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Edit'),
                                          ),
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }
}


// ============================================================
// PLOT HISTORY
// ============================================================

class PlotHistoryPage extends StatefulWidget {
  const PlotHistoryPage({
    super.key,
    this.standalone = false,
  });

  final bool standalone;

  @override
  State<PlotHistoryPage> createState() => _PlotHistoryPageState();
}

class _PlotHistoryPageState extends State<PlotHistoryPage> {
  List<Map<String, dynamic>> _plots = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPlots();
  }

  Future<void> _loadPlots() async {
    try {
      final plots = await AppDatabase.instance.getPlots();

      if (!mounted) return;

      setState(() {
        _plots = plots;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load plots: $e')),
      );
    }
  }

  Future<void> _showPlotDialog({
    Map<String, dynamic>? plot,
  }) async {
    final titleController = TextEditingController(
      text: plot == null ? '' : plot['title'].toString(),
    );

    final plotNameController = TextEditingController(
      text: plot == null ? '' : plot['plot_name'].toString(),
    );

    final cropController = TextEditingController(
      text: plot == null ? '' : plot['crop_variety'].toString(),
    );

    final editing = plot != null;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            editing ? 'Edit plot / crop' : 'Add plot / crop',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'Example: Farm 1 - Cotton',
                    prefixIcon: Icon(Icons.title),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: plotNameController,
                  decoration: const InputDecoration(
                    labelText: 'Plot name or number (optional)',
                    hintText: 'Example: Plot 2',
                    prefixIcon: Icon(Icons.landscape),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cropController,
                  decoration: const InputDecoration(
                    labelText: 'Crop variety (optional)',
                    hintText: 'Example: Cotton',
                    prefixIcon: Icon(Icons.grass),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final title = titleController.text.trim();
                final plotName = plotNameController.text.trim();
                final crop = cropController.text.trim();

                if (title.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enter a title.')),
                  );
                  return;
                }

                if (editing) {
                  await AppDatabase.instance.updatePlot(
                    id: plot['id'] as int,
                    title: title,
                    plotName: plotName,
                    cropVariety: crop,
                  );
                } else {
                  await AppDatabase.instance.addPlot(
                    title: title,
                    plotName: plotName,
                    cropVariety: crop,
                  );
                }

                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                if (!mounted) return;
                await _loadPlots();
              },
              child: Text(editing ? 'Save' : 'Add'),
            ),
          ],
        );
      },
    );

    titleController.dispose();
    plotNameController.dispose();
    cropController.dispose();
  }

  Future<void> _exportHistory() async {
    try {
      final payload = await AppDatabase.instance.exportHistory();
      final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
      final fileName =
          'FarmBook_history_${DateTime.now().millisecondsSinceEpoch}.json';

      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Backup FarmBook Plot Data',
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null) return;

      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(path)],
        text: 'FarmBook plot backup',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('History backup failed: $e')),
      );
    }
  }

  Future<void> _importHistory() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: false,
      );

      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;
      final text = await File(path).readAsString();
      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid FarmBook history backup.');
      }

      if (decoded['format']?.toString() != 'FarmBook plot backup' &&
          decoded['format']?.toString() != 'FarmBook spray history backup' &&
          decoded['format']?.toString() != 'SprayBook spray history backup') {
        throw const FormatException(
          'This file is not a FarmBook backup.',
        );
      }

      if (!mounted) return;
      final shouldRestore = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Restore Spray History?'),
          content: const Text(
            'The backup will be added to your existing history. '
            'Existing data will not be deleted. Exact duplicate records '
            'will be skipped.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );

      if (shouldRestore != true) return;

      final resultCounts = await AppDatabase.instance.restoreHistory(decoded);
      await _loadPlots();

      if (!mounted) return;
      final plotsAdded = resultCounts['plots_added'] ?? 0;
      final spraysAdded = resultCounts['sprays_added'] ?? 0;
      final dripsAdded = resultCounts['drips_added'] ?? 0;
      final skipped = resultCounts['skipped'] ?? 0;
      final labourAdded = resultCounts['labour_added'] ?? 0;
      final otherAdded = resultCounts['other_added'] ?? 0;
      final earningsAdded = resultCounts['earnings_added'] ?? 0;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restore complete: $plotsAdded plots, $spraysAdded sprays, $dripsAdded drips, '
            '$labourAdded labour, $otherAdded expenses, $earningsAdded earnings added${skipped == 0 ? '' : ', $skipped skipped'}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('History restore failed: $e')),
      );
    }
  }

  Future<void> _deletePlot(
    Map<String, dynamic> plot,
  ) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete plot / crop?'),
          content: Text(
            'This will also delete all spray records belonging to "${plot['title']}".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (delete != true) return;

    await AppDatabase.instance.deletePlot(
      plot['id'] as int,
    );

    await _loadPlots();
  }

  Future<void> _openPlot(Map<String, dynamic> plot) async {
    final id=plot['id'] as int; final direct=await AppDatabase.instance.directLastPageEnabled(); final last=direct?await AppDatabase.instance.getLastPage(id):null;
    Widget page=PlotOverviewPage(plotId:id,plotTitle:plot['title'].toString(),plotName:plot['plot_name'].toString(),cropVariety:plot['crop_variety'].toString());
    if(direct && last!=null){
      final title=plot['title'].toString(), name=plot['plot_name'].toString(), crop=plot['crop_variety'].toString();
      if(last=='spray'){ page=PlotSpraysPage(plotId:id,plotTitle:title,plotName:name,cropVariety:crop); }
      else if(last=='drip'){ page=PlotSpraysPage(plotId:id,plotTitle:title,plotName:name,cropVariety:crop,initialTab:1); }
      else if(last=='labour'){ page=LabourPage(plotId:id,plotTitle:title); }
      else if(last=='other'){ page=OtherExpensesPage(plotId:id,plotTitle:title); }
      else if(last=='earnings'){ page=EarningsPage(plotId:id,plotTitle:title); }
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder:(_)=>page)); await _loadPlots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FarmBook'),
        actions: [
          IconButton(tooltip: 'Farm Overview', icon: const Icon(Icons.analytics_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FarmOverviewPage()))),
          IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()))),
          PopupMenuButton<String>(
            tooltip: 'Backup or restore history',
            onSelected: (value) {
              if (value == 'backup') {
                _exportHistory();
              } else if (value == 'restore') {
                _importHistory();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'backup',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.upload_file),
                  title: Text('FarmBook Plot Backup'),
                ),
              ),
              PopupMenuItem(
                value: 'restore',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.download),
                  title: Text('FarmBook Plot Restore'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        onPressed: () => _showPlotDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Add plot / crop'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : _plots.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(30),
                    child: Text(
                      'No plots saved yet.\n\nCreate a plot/crop title to start recording sprays.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadPlots,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      100,
                    ),
                    itemCount: _plots.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final plot = _plots[index];

                      // The first history page intentionally displays
                      // only the saved plot/crop title.
                      return Card(
                        child: ListTile(
                          title: Text(
                            plot['title'].toString(),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0D47A1),
                            ),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'open') {
                                _openPlot(plot);
                              } else if (value == 'edit') {
                                _showPlotDialog(plot: plot);
                              } else if (value == 'delete') {
                                _deletePlot(plot);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'open',
                                child: Text('Open'),
                              ),
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                          onTap: () => _openPlot(plot),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}



// ============================================================
// FARM OVERVIEW / FINANCE
// ============================================================



class PlotOverviewPage extends StatefulWidget {
  const PlotOverviewPage({
    super.key,
    required this.plotId,
    required this.plotTitle,
    required this.plotName,
    required this.cropVariety,
  });

  final int plotId;
  final String plotTitle;
  final String plotName;
  final String cropVariety;

  @override
  State<PlotOverviewPage> createState() => _PlotOverviewPageState();
}

class _PlotOverviewPageState extends State<PlotOverviewPage> {
  Map<String, double> totals = {};
  bool loading = true;
  bool _hasEarnings = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    totals = await AppDatabase.instance.plotTotals(widget.plotId);
    final earnings = await AppDatabase.instance.getEarnings(widget.plotId);
    if (!mounted) return;
    setState(() {
      _hasEarnings = earnings.isNotEmpty;
      loading = false;
    });
  }

  Future<void> _openSection(String page, Widget child) async {
    await AppDatabase.instance.setLastPage(widget.plotId, page);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => child),
    );
    await _load();
  }

  Widget _row(String title, double value, VoidCallback onTap) {
    return Card(
      child: ListTile(
        title: Text(title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              fbMoney(value),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  Future<void> _exportPlot() async {
    try {
      final payload = await AppDatabase.instance.exportPlot(widget.plotId);
      final text = const JsonEncoder.withIndent('  ').convert(payload);
      final bytes = Uint8List.fromList(utf8.encode(text));
      final safe = widget.plotTitle.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Plot Data',
        fileName: 'FarmBook_$safe.json',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null || !mounted) return;
      await Share.shareXFiles(
        [XFile(path)],
        text: 'FarmBook plot data',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final expense = totals['expense'] ?? 0;
    final earnings = totals['earnings'] ?? 0;
    final profit = totals['profit'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.plotTitle),
        actions: [
          IconButton(
            tooltip: 'Export this plot',
            icon: const Icon(Icons.share),
            onPressed: _exportPlot,
          ),
          IconButton(
            tooltip: 'Plot information',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(widget.plotTitle),
                  content: Text(
                    'Plot: ${widget.plotName}\n'
                    'Crop variety: ${widget.cropVariety}',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  Card(
                    color: const Color(0xFFE3F2FD),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'PLOT OVERVIEW',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0D47A1),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('Total Expense', style: TextStyle(color: Colors.grey)),
                          Text(
                            fbMoney(expense),
                            style: const TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0D47A1),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text('Total Earnings', style: TextStyle(color: Colors.grey)),
                          Text(
                            _hasEarnings ? fbMoney(earnings) : '—',
                            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                          ),
                          const Divider(height: 28),
                          // Never show a Profit/Loss figure before any
                          // earning has actually been recorded — it would
                          // just be the negative expense total, not a real
                          // profit or loss.
                          Text(
                            _hasEarnings
                                ? (profit >= 0 ? 'PROFIT' : 'LOSS')
                                : 'PROFIT / LOSS',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: !_hasEarnings
                                  ? Colors.grey
                                  : (profit >= 0 ? Colors.green.shade700 : Colors.red.shade700),
                            ),
                          ),
                          Text(
                            _hasEarnings ? fbMoney(profit.abs()) : '—',
                            style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.bold,
                              color: !_hasEarnings
                                  ? Colors.grey
                                  : (profit >= 0 ? Colors.green.shade700 : Colors.red.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _row(
                    '🌿 Spray',
                    totals['spray'] ?? 0,
                    () => _openSection(
                      'spray',
                      PlotSpraysPage(
                        plotId: widget.plotId,
                        plotTitle: widget.plotTitle,
                        plotName: widget.plotName,
                        cropVariety: widget.cropVariety,
                      ),
                    ),
                  ),
                  _row(
                    '💧 Drip / Irrigation',
                    totals['drip'] ?? 0,
                    () => _openSection(
                      'drip',
                      PlotSpraysPage(
                        plotId: widget.plotId,
                        plotTitle: widget.plotTitle,
                        plotName: widget.plotName,
                        cropVariety: widget.cropVariety,
                        initialTab: 1,
                      ),
                    ),
                  ),
                  _row(
                    '👷 Labour',
                    totals['labour'] ?? 0,
                    () => _openSection(
                      'labour',
                      LabourPage(plotId: widget.plotId, plotTitle: widget.plotTitle),
                    ),
                  ),
                  _row(
                    '📦 Other Expenses',
                    totals['other'] ?? 0,
                    () => _openSection(
                      'other',
                      OtherExpensesPage(plotId: widget.plotId, plotTitle: widget.plotTitle),
                    ),
                  ),
                  _row(
                    '💰 Earnings',
                    totals['earnings'] ?? 0,
                    () => _openSection(
                      'earnings',
                      EarningsPage(plotId: widget.plotId, plotTitle: widget.plotTitle),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool direct = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    direct = await AppDatabase.instance.directLastPageEnabled();
    if (!mounted) return;
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: SwitchListTile(
                    title: const Text('Direct open last page'),
                    subtitle: const Text(
                      'When you tap a plot, open the last section you used instead of Plot Overview.',
                    ),
                    value: direct,
                    onChanged: (value) async {
                      await AppDatabase.instance.setDirectLastPageEnabled(value);
                      if (mounted) setState(() => direct = value);
                    },
                  ),
                ),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.offline_bolt),
                    title: Text('Offline storage'),
                    subtitle: Text('FarmBook records stay on this phone. No login or server is required.'),
                  ),
                ),
              ],
            ),
    );
  }
}

class LabourPage extends StatefulWidget {
  const LabourPage({super.key, required this.plotId, required this.plotTitle});
  final int plotId;
  final String plotTitle;
  @override
  State<LabourPage> createState() => _LabourPageState();
}

class _LabourPageState extends State<LabourPage> {
  List<Map<String, dynamic>> rows = [];
  bool loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    rows = await AppDatabase.instance.getLabour(widget.plotId);
    if (mounted) setState(() => loading = false);
  }

  Future<void> _form([Map<String, dynamic>? row]) async {
    final work = TextEditingController(text: row?['work_type']?.toString() ?? '');
    final workers = TextEditingController(text: row == null ? '' : (row['worker_count'] as num).toString());
    final rate = TextEditingController(text: row == null ? '' : (row['rate'] as num).toString());
    final amount = TextEditingController(text: row == null ? '' : (row['total_cost'] as num).toString());
    final notes = TextEditingController(text: row?['notes']?.toString() ?? '');
    DateTime date = row == null ? DateTime.now() : DateTime.parse(row['labour_date'].toString());

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(row == null ? 'Add labour' : 'Edit labour'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: work, decoration: const InputDecoration(labelText: 'Work type')),
                TextField(controller: workers, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Workers / days')),
                TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Rate per worker / day')),
                TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Total cost (₹)')),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('Date'),
                  subtitle: Text(formatDate(date)),
                  onTap: () async {
                    final picked = await showDatePicker(context: dialogContext, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime(2100));
                    if (picked != null) setDialogState(() => date = picked);
                  },
                ),
                TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final total = double.tryParse(amount.text.trim());
                if (work.text.trim().isEmpty || total == null || total < 0) return;
                final count = double.tryParse(workers.text.trim()) ?? 0;
                final rt = double.tryParse(rate.text.trim()) ?? 0;
                if (row == null) {
                  await AppDatabase.instance.addLabour(plotId: widget.plotId, date: date, workType: work.text, workerCount: count, rate: rt, totalCost: total, notes: notes.text);
                } else {
                  await AppDatabase.instance.updateLabour(id: row['id'] as int, date: date, workType: work.text, workerCount: count, rate: rt, totalCost: total, notes: notes.text);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                await _load();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    work.dispose(); workers.dispose(); rate.dispose(); amount.dispose(); notes.dispose();
  }

  Future<void> _delete(int id) async { await AppDatabase.instance.deleteLabour(id); await _load(); }

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<double>(0, (sum, row) => sum + (row['total_cost'] as num).toDouble());
    return Scaffold(
      appBar: AppBar(title: Text('${widget.plotTitle} • Labour')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _form(), backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white,
        icon: const Icon(Icons.add), label: const Text('Add labour'),
      ),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
        children: [
          Card(color: const Color(0xFFE3F2FD), child: ListTile(title: const Text('Total Labour Cost'), trailing: Text(fbMoney(total), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Color(0xFF0D47A1))))),
          ...rows.map((row) => Card(child: ListTile(
            title: Text(row['work_type'].toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${formatDate(DateTime.parse(row['labour_date'].toString()))} • ${(row['worker_count'] as num)} workers × ₹${(row['rate'] as num).toStringAsFixed(2)}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [Text(fbMoney((row['total_cost'] as num).toDouble())), PopupMenuButton<String>(onSelected: (v) { if (v == 'edit') { _form(row); } else { _delete(row['id'] as int); } }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))])]),
          )))
        ],
      ),
    );
  }
}

class OtherExpensesPage extends StatefulWidget {
  const OtherExpensesPage({super.key, required this.plotId, required this.plotTitle});
  final int plotId;
  final String plotTitle;
  @override State<OtherExpensesPage> createState() => _OtherExpensesPageState();
}

class _OtherExpensesPageState extends State<OtherExpensesPage> {
  List<Map<String, dynamic>> rows = [];
  bool loading = true;
  final categories = const ['Seeds / Plants', 'Fertilizer', 'Electricity', 'Diesel', 'Machinery', 'Transport', 'Rent', 'Repairs', 'Packaging', 'Other'];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { rows = await AppDatabase.instance.getOtherExpenses(widget.plotId); if (mounted) setState(() => loading = false); }
  Future<void> _form([Map<String, dynamic>? row]) async {
    final desc = TextEditingController(text: row?['description']?.toString() ?? '');
    final amount = TextEditingController(text: row == null ? '' : (row['amount'] as num).toString());
    final notes = TextEditingController(text: row?['notes']?.toString() ?? '');
    String category = row?['category']?.toString() ?? categories.first;
    DateTime date = row == null ? DateTime.now() : DateTime.parse(row['expense_date'].toString());
    await showDialog<void>(context: context, builder: (dc) => StatefulBuilder(builder: (dc, set) => AlertDialog(
      title: Text(row == null ? 'Add expense' : 'Edit expense'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(value: categories.contains(category) ? category : categories.last, items: categories.map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(), onChanged: (v) { if (v != null) set(() => category = v); }, decoration: const InputDecoration(labelText: 'Category')),
        TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (₹)')),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.calendar_today), title: const Text('Date'), subtitle: Text(formatDate(date)), onTap: () async { final picked = await showDatePicker(context: dc, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (picked != null) set(() => date = picked); }),
        TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Cancel')), FilledButton(onPressed: () async { final value = double.tryParse(amount.text.trim()); if (desc.text.trim().isEmpty || value == null || value < 0) return; if (row == null) { await AppDatabase.instance.addOtherExpense(plotId: widget.plotId, date: date, category: category, description: desc.text, amount: value, notes: notes.text); } else { await AppDatabase.instance.updateOtherExpense(id: row['id'] as int, date: date, category: category, description: desc.text, amount: value, notes: notes.text); } if (dc.mounted) Navigator.pop(dc); await _load(); }, child: const Text('Save'))],
    ))); desc.dispose(); amount.dispose(); notes.dispose();
  }
  Future<void> _delete(int id) async { await AppDatabase.instance.deleteOtherExpense(id); await _load(); }
  @override Widget build(BuildContext context) { final total=rows.fold<double>(0,(sum,row)=>sum+(row['amount']as num).toDouble()); return Scaffold(appBar:AppBar(title:Text('${widget.plotTitle} • Expenses')),floatingActionButton:FloatingActionButton.extended(onPressed:()=>_form(),backgroundColor:const Color(0xFF0D47A1),foregroundColor:Colors.white,icon:const Icon(Icons.add),label:const Text('Add expense')),body:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.fromLTRB(12,12,12,100),children:[Card(color:const Color(0xFFE3F2FD),child:ListTile(title:const Text('Total Other Expenses'),trailing:Text(fbMoney(total),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold,color:Color(0xFF0D47A1))))),...rows.map((row)=>Card(child:ListTile(title:Text(row['description'].toString()),subtitle:Text('${row['category']} • ${formatDate(DateTime.parse(row['expense_date'].toString()))}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(fbMoney((row['amount']as num).toDouble())),PopupMenuButton<String>(onSelected:(v){if(v=='edit'){_form(row);}else{_delete(row['id']as int);}},itemBuilder:(_)=>const[PopupMenuItem(value:'edit',child:Text('Edit')),PopupMenuItem(value:'delete',child:Text('Delete'))])]))))])); }
}

/// Standard unit choices for earnings. "other" allows a free-text unit.
const List<String> kFbEarningUnits = [
  'kg', 'quintal', 'ton', 'box', 'crate', 'bag', 'piece', 'litre', 'other',
];

class EarningsPage extends StatefulWidget {
  const EarningsPage({super.key, required this.plotId, required this.plotTitle});
  final int plotId; final String plotTitle;
  @override State<EarningsPage> createState() => _EarningsPageState();
}

class _EarningsPageState extends State<EarningsPage> {
  List<Map<String, dynamic>> rows = [];
  List<Map<String, dynamic>> _plots = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    rows = await AppDatabase.instance.getEarnings(widget.plotId);
    _plots = await AppDatabase.instance.getPlots();
    if (mounted) setState(() => loading = false);
  }

  Future<void> _form([Map<String, dynamic>? row]) async {
    final desc = TextEditingController(text: row?['description']?.toString() ?? '');
    final notes = TextEditingController(text: row?['notes']?.toString() ?? '');

    final existingQty = row == null ? 0.0 : (row['quantity'] as num).toDouble();
    final existingPrice = row == null ? 0.0 : (row['price'] as num).toDouble();
    final existingAmount = row == null ? 0.0 : (row['amount'] as num).toDouble();
    final existingUnit = row?['unit']?.toString() ?? '';

    final qtyCtrl = TextEditingController(
      text: existingQty != 0 ? formatNumber(existingQty) : '',
    );
    final rateCtrl = TextEditingController(
      text: existingPrice != 0 ? formatNumber(existingPrice) : '',
    );
    final amountCtrl = TextEditingController(
      text: existingAmount != 0 ? formatNumber(existingAmount) : '',
    );

    String unit = kFbEarningUnits.contains(existingUnit)
        ? existingUnit
        : (existingUnit.isEmpty ? 'kg' : 'other');
    final customUnitCtrl = TextEditingController(
      text: unit == 'other' ? existingUnit : '',
    );

    DateTime date = row == null ? DateTime.now() : DateTime.parse(row['earning_date'].toString());

    // Default plot selection: the plot this page is scoped to, if it still
    // exists; otherwise the first available plot.
    int selectedPlotId = widget.plotId;
    if (_plots.isNotEmpty && _plots.every((p) => (p['id'] as int) != selectedPlotId)) {
      selectedPlotId = _plots.first['id'] as int;
    }

    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) {
          // Rate is optional. When it's provided, Amount is calculated
          // automatically from Yield × Rate. When Rate is left blank, the
          // farmer can key in the total earning directly (Yield can still
          // be recorded either way, matching a simple sale record).
          final rateProvided = rateCtrl.text.trim().isNotEmpty;
          if (rateProvided) {
            final q = double.tryParse(qtyCtrl.text.trim()) ?? 0;
            final r = double.tryParse(rateCtrl.text.trim()) ?? 0;
            amountCtrl.text = formatNumber(q * r);
          }
          final unitLabel = unit == 'other'
              ? (customUnitCtrl.text.trim().isEmpty ? 'unit' : customUnitCtrl.text.trim())
              : unit;

          return AlertDialog(
            title: Text(row == null ? 'Add earning' : 'Edit earning'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: desc,
                    decoration: const InputDecoration(labelText: 'Description (optional)'),
                  ),
                  const SizedBox(height: 12),
                  if (row == null && _plots.length > 1) ...[
                    DropdownButtonFormField<int>(
                      value: selectedPlotId,
                      decoration: const InputDecoration(labelText: 'Crop / Plot (optional)'),
                      items: _plots
                          .map((p) => DropdownMenuItem<int>(
                                value: p['id'] as int,
                                child: Text(
                                  p['title'].toString(),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) set(() => selectedPlotId = v);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: qtyCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Yield (optional)'),
                          onChanged: (_) => set(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          value: unit,
                          decoration: const InputDecoration(labelText: 'Unit'),
                          items: kFbEarningUnits
                              .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) set(() => unit = v);
                          },
                        ),
                      ),
                    ],
                  ),
                  if (unit == 'other') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: customUnitCtrl,
                      decoration: const InputDecoration(labelText: 'Custom unit'),
                      onChanged: (_) => set(() {}),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: rateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Rate / $unitLabel (optional, ₹)',
                    ),
                    onChanged: (_) => set(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    enabled: !rateProvided,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Total earning (₹)',
                      helperText: rateProvided
                          ? 'Calculated from yield × rate'
                          : 'Enter the total earning directly',
                    ),
                    onChanged: (_) => set(() {}),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_today),
                    title: const Text('Date'),
                    subtitle: Text(formatDate(date)),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: dc,
                        initialDate: date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) set(() => date = picked);
                    },
                  ),
                  TextField(
                    controller: notes,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Notes (optional)'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  final q = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                  final r = double.tryParse(rateCtrl.text.trim()) ?? 0;
                  final a = double.tryParse(amountCtrl.text.trim());
                  if (a == null || a < 0) return;
                  if (q < 0 || r < 0) return;

                  final savedUnit = q > 0
                      ? (unit == 'other' ? customUnitCtrl.text.trim() : unit)
                      : '';

                  if (row == null) {
                    await AppDatabase.instance.addEarning(
                      plotId: selectedPlotId,
                      date: date,
                      description: desc.text,
                      quantity: q,
                      unit: savedUnit,
                      price: r,
                      amount: a,
                      notes: notes.text,
                    );
                  } else {
                    await AppDatabase.instance.updateEarning(
                      id: row['id'] as int,
                      date: date,
                      description: desc.text,
                      quantity: q,
                      unit: savedUnit,
                      price: r,
                      amount: a,
                      notes: notes.text,
                    );
                  }
                  if (dc.mounted) Navigator.pop(dc);
                  await _load();
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    desc.dispose();
    notes.dispose();
    amountCtrl.dispose();
    qtyCtrl.dispose();
    rateCtrl.dispose();
    customUnitCtrl.dispose();
  }

  Future<void> _delete(int id) async {
    await AppDatabase.instance.deleteEarning(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...rows]
      ..sort(
        (a, b) => DateTime.parse(a['earning_date'].toString())
            .compareTo(DateTime.parse(b['earning_date'].toString())),
      );

    final totalAmount = rows.fold<double>(
      0,
      (sum, row) => sum + (row['amount'] as num).toDouble(),
    );
    final totalYield = rows.fold<double>(
      0,
      (sum, row) => sum + (row['quantity'] as num).toDouble(),
    );
    final yieldUnit = rows
        .map((r) => r['unit'].toString())
        .firstWhere((u) => u.isNotEmpty, orElse: () => 'kg');

    Widget headerCell(String text, int flex, {TextAlign align = TextAlign.left}) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 11,
              color: Color(0xFF315B88),
            ),
          ),
        ),
      );
    }

    Widget valueCell(
      String text,
      int flex, {
      bool bold = false,
      TextAlign align = TextAlign.left,
    }) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 11),
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: TextStyle(
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              fontSize: 11,
              color: bold ? const Color(0xFF17395C) : null,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('${widget.plotTitle} • Earnings')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _form(),
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add earning'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : rows.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'No earning records yet.\n\nUse "Add earning" to record a sale (yield × rate, or a total amount).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 100),
                  children: [
                    Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFFE8F2FD),
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: Row(
                        children: [
                          headerCell('No.', 8, align: TextAlign.center),
                          headerCell('Date', 23),
                          headerCell('Yield', 20, align: TextAlign.right),
                          headerCell('Rate', 19, align: TextAlign.right),
                          headerCell('Amount', 25, align: TextAlign.right),
                          const SizedBox(width: 25),
                        ],
                      ),
                    ),
                    ...List.generate(sorted.length, (index) {
                      final row = sorted[index];
                      final qty = (row['quantity'] as num).toDouble();
                      final price = (row['price'] as num).toDouble();
                      final amount = (row['amount'] as num).toDouble();
                      final unit = row['unit'].toString();
                      final date =
                          formatDate(DateTime.parse(row['earning_date'].toString()));

                      return Material(
                        color: index.isEven
                            ? Colors.white
                            : const Color(0xFFFAFCFF),
                        child: InkWell(
                          onTap: () => _form(row),
                          child: Container(
                            decoration: const BoxDecoration(
                              border: Border(
                                left: BorderSide(color: Color(0xFFDCE8F4)),
                                right: BorderSide(color: Color(0xFFDCE8F4)),
                                bottom: BorderSide(color: Color(0xFFDCE8F4)),
                              ),
                            ),
                            child: Row(
                              children: [
                                valueCell(
                                  '${index + 1}',
                                  8,
                                  align: TextAlign.center,
                                ),
                                valueCell(date, 23),
                                valueCell(
                                  qty > 0
                                      ? '${formatNumber(qty)} $unit'
                                      : '—',
                                  20,
                                  align: TextAlign.right,
                                ),
                                valueCell(
                                  price > 0
                                      ? '₹${formatNumber(price)}'
                                      : '—',
                                  19,
                                  align: TextAlign.right,
                                ),
                                valueCell(
                                  fbMoney(amount),
                                  25,
                                  bold: true,
                                  align: TextAlign.right,
                                ),
                                SizedBox(
                                  width: 25,
                                  child: IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 25,
                                      minHeight: 32,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                      size: 18,
                                    ),
                                    onPressed: () =>
                                        _delete(row['id'] as int),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFFE9F7F1),
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(12),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 13,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            flex: 31,
                            child: Text(
                              'Total',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 20,
                            child: Text(
                              totalYield > 0
                                  ? '${formatNumber(totalYield)} $yieldUnit'
                                  : '—',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: Color(0xFF00796B),
                              ),
                            ),
                          ),
                          const Spacer(flex: 19),
                          Expanded(
                            flex: 25,
                            child: Text(
                              fbMoney(totalAmount),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Color(0xFF00796B),
                              ),
                            ),
                          ),
                          const SizedBox(width: 25),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class PesticideUsagePage extends StatefulWidget {
  const PesticideUsagePage({super.key});

  @override
  State<PesticideUsagePage> createState() => _PesticideUsagePageState();
}

class _PesticideUsagePageState extends State<PesticideUsagePage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  int? _selectedYear;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await AppDatabase.instance.getPesticideUsageRows();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        final years = _availableYears();
        if (years.isEmpty) {
          _selectedYear = null;
        } else if (_selectedYear == null || !years.contains(_selectedYear)) {
          _selectedYear = years.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not calculate pesticide usage: $e';
      });
    }
  }

  int _rowYear(Map<String, dynamic> row) {
    return DateTime.parse(row['spray_date'].toString()).year;
  }

  List<int> _availableYears() {
    final years = <int>{for (final row in _rows) _rowYear(row)}.toList()
      ..sort((a, b) => b.compareTo(a));
    return years;
  }

  double _rawUsage(Map<String, dynamic> row) {
    return (row['water'] as num).toDouble() *
        (row['dosage'] as num).toDouble();
  }

  // Prefer the dosage unit saved with the spray-chemical row. Older rows may
  // only have the chemical's configured unit, so fall back to that.
  String _sourceUnit(Map<String, dynamic> row) {
    final dosageUnit = row['dosage_unit']?.toString().trim() ?? '';
    if (dosageUnit.isNotEmpty) return dosageUnit;
    return row['unit']?.toString().trim() ?? '';
  }

  String _unitKey(String unit) {
    final u = unit.trim().toLowerCase();
    if (u == 'ml' ||
        u == 'l' ||
        u == 'litre' ||
        u == 'liter' ||
        u == 'litres' ||
        u == 'liters') {
      return 'L';
    }
    if (u == 'gram' || u == 'g' || u == 'grams' || u == 'kg') {
      return 'kg';
    }
    return unit.trim().isEmpty ? 'unit' : unit.trim();
  }

  double _normalizedUsage(Map<String, dynamic> row) {
    final value = _rawUsage(row);
    final unit = _sourceUnit(row).toLowerCase();
    if (unit == 'ml') return value / 1000.0;
    if (unit == 'gram' || unit == 'g' || unit == 'grams') {
      return value / 1000.0;
    }
    return value;
  }

  String _formatUsage(double value) {
    if (value.abs() >= 100) return value.toStringAsFixed(1);
    if (value.abs() >= 10) return value.toStringAsFixed(2);
    return value.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  Map<String, Map<String, double>> _groupedForYear(int? year) {
    final result = <String, Map<String, double>>{};
    for (final row in _rows) {
      if (year != null && _rowYear(row) != year) continue;
      final name = row['chemical_name'].toString().trim();
      if (name.isEmpty) continue;
      final crop = row['crop_variety'].toString().trim().isEmpty
          ? row['plot_title'].toString().trim()
          : row['crop_variety'].toString().trim();
      final unit = _unitKey(_sourceUnit(row));
      final amount = _normalizedUsage(row);
      final pesticide = result.putIfAbsent(name, () => {});
      // A chemical's configured unit determines the normalized display unit.
      // Volume is normalized to L and weight to kg. Other units are kept as-is.
      final key = '$crop|$unit';
      pesticide[key] = (pesticide[key] ?? 0) + amount;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final years = _availableYears();
    final selected = _selectedYear;
    final grouped = _groupedForYear(selected);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pesticide Usage'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    children: [
                      if (years.isNotEmpty)
                        DropdownButtonFormField<int>(
                          value: selected,
                          decoration: const InputDecoration(
                            labelText: 'Year',
                            prefixIcon: Icon(Icons.calendar_today_outlined),
                          ),
                          items: years
                              .map((year) => DropdownMenuItem<int>(
                                    value: year,
                                    child: Text(year.toString()),
                                  ))
                              .toList(),
                          onChanged: (value) => setState(() => _selectedYear = value),
                        ),
                      if (years.isEmpty)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'No spray records with pesticide usage yet.\n\nAdd a Spray record first, and FarmBook will calculate usage automatically.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ...grouped.entries.map((entry) {
                        final cropRows = <String, double>{};
                        final cropUnits = <String, String>{};
                        for (final item in entry.value.entries) {
                          final split = item.key.split('|');
                          final crop = split.first;
                          final unit = split.length > 1 ? split[1] : 'unit';
                          final cropKey = '$crop|$unit';
                          cropRows[cropKey] = (cropRows[cropKey] ?? 0) + item.value;
                          cropUnits[cropKey] = unit;
                        }
                        final totalsByUnit = <String, double>{};
                        for (final item in cropRows.entries) {
                          final unit = cropUnits[item.key] ?? 'unit';
                          totalsByUnit[unit] = (totalsByUnit[unit] ?? 0) + item.value;
                        }
                        return Card(
                          margin: const EdgeInsets.only(top: 10),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.key,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                ...cropRows.entries.map(
                                  (crop) {
                                    final split = crop.key.split('|');
                                    final cropName = split.first;
                                    final unit = cropUnits[crop.key] ?? 'unit';
                                    return ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(cropName),
                                      trailing: Text(
                                        '${_formatUsage(crop.value)} $unit',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                    );
                                  },
                                ),
                                const Divider(),
                                ...totalsByUnit.entries.map(
                                  (totalEntry) => ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      totalsByUnit.length == 1 ? 'Total used' : 'Total used (${totalEntry.key})',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    trailing: Text(
                                      '${_formatUsage(totalEntry.value)} ${totalEntry.key}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
    );
  }
}

class FarmOverviewPage extends StatefulWidget { const FarmOverviewPage({super.key}); @override State<FarmOverviewPage> createState()=>_FarmOverviewPageState(); }
class _FarmOverviewPageState extends State<FarmOverviewPage> {
  Map<String, double> totals = {};
  bool loading = true;
  bool _hasEarnings = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    totals = await AppDatabase.instance.allPlotTotals();
    var earningsCount = 0;
    for (final plot in await AppDatabase.instance.getPlots()) {
      final earnings = await AppDatabase.instance.getEarnings(plot['id'] as int);
      earningsCount += earnings.length;
      if (earningsCount > 0) break;
    }
    if (!mounted) return;
    setState(() {
      _hasEarnings = earningsCount > 0;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final expense = totals['expense'] ?? 0;
    final earnings = totals['earnings'] ?? 0;
    final profit = totals['profit'] ?? 0;
    final profitColor = !_hasEarnings
        ? Colors.grey
        : (profit >= 0 ? Colors.green.shade700 : Colors.red.shade700);

    return Scaffold(
      appBar: AppBar(title: const Text('Farm Overview')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  Card(
                    color: const Color(0xFFE3F2FD),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ALL PLOTS',
                            style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0D47A1)),
                          ),
                          const SizedBox(height: 12),
                          Text('Total Expenses  ${fbMoney(expense)}'),
                          Text('Total Earnings  ${_hasEarnings ? fbMoney(earnings) : '—'}'),
                          const Divider(),
                          Text(
                            _hasEarnings ? (profit >= 0 ? 'TOTAL PROFIT' : 'TOTAL LOSS') : 'TOTAL PROFIT / LOSS',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _hasEarnings ? fbMoney(profit.abs()) : '—',
                            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: profitColor),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _farmTotal('Spray', totals['spray'] ?? 0),
                  _farmTotal('Drip / Irrigation', totals['drip'] ?? 0),
                  _farmTotal('Labour', totals['labour'] ?? 0),
                  _farmTotal('Other Expenses', totals['other'] ?? 0),
                ],
              ),
            ),
    );
  }

  Widget _farmTotal(String title, double value) => Card(
        child: ListTile(
          title: Text(title),
          trailing: Text(fbMoney(value), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
}

// ============================================================
// PLOT HISTORY / SPRAY + DRIP PAGE
// ============================================================

class PlotSpraysPage extends StatefulWidget {
  const PlotSpraysPage({
    super.key,
    required this.plotId,
    required this.plotTitle,
    required this.plotName,
    required this.cropVariety,
    this.initialTab = 0,
  });

  final int plotId;
  final String plotTitle;
  final String plotName;
  final String cropVariety;

  /// 0 = Spray tab, 1 = Drip tab.
  final int initialTab;

  @override
  State<PlotSpraysPage> createState() => _PlotSpraysPageState();
}

class _PlotSpraysPageState extends State<PlotSpraysPage> {
  List<Map<String, dynamic>> _records = [];
  int _recordTab = 0;
  bool _loading = true;
  String? _loadError;

  // When off, only chemical names are shown. When on, each chemical also
  // shows the saved dosage, for example "Tata Bahaar (2 ml) + Soloman (1 ml)".
  bool _showDosage = false;

  String _chemicalWithDosage(Map<String, dynamic> chemical) {
    final name = chemical['chemical_name'].toString().trim();
    final dosageRaw = chemical['dosage'];
    final dosage = dosageRaw is num
        ? formatNumber(dosageRaw.toDouble())
        : '';
    final unit = chemical['dosage_unit']?.toString().trim() ??
        chemical['unit']?.toString().trim() ??
        '';

    if (dosage.isEmpty || dosage == '0') return name;
    return unit.isEmpty ? '$name ($dosage)' : '$name ($dosage $unit)';
  }

  @override
  void initState() {
    super.initState();
    _recordTab = widget.initialTab;
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }

    try {
      final sprays =
          await AppDatabase.instance.getSpraysForPlot(widget.plotId);
      final drips =
          await AppDatabase.instance.getDripApplicationsForPlot(widget.plotId);

      final records = <Map<String, dynamic>>[];

      for (final spray in sprays) {
        final chemicals =
            await AppDatabase.instance.getSprayChemicals(spray['id'] as int);
        records.add({
          'record_type': 'Spray',
          'id': spray['id'],
          'date': spray['spray_date'],
          'quantity': (spray['water'] as num).toDouble(),
          'total_cost': (spray['total_cost'] as num).toDouble(),
          'notes': spray['notes'].toString(),
          'chemicals': chemicals
              .map((c) => c['chemical_name'].toString())
              .join(' + '),
          'chemicals_dosage':
              chemicals.map(_chemicalWithDosage).join(' + '),
          'original': spray,
        });
      }

      for (final drip in drips) {
        final chemicals =
            await AppDatabase.instance.getDripChemicals(drip['id'] as int);
        records.add({
          'record_type': 'Drip',
          'id': drip['id'],
          'date': drip['drip_date'],
          'quantity': (drip['acres'] as num).toDouble(),
          'total_cost': (drip['total_cost'] as num).toDouble(),
          'notes': drip['notes'].toString(),
          'chemicals': chemicals
              .map((c) => c['chemical_name'].toString())
              .join(' + '),
          'chemicals_dosage':
              chemicals.map(_chemicalWithDosage).join(' + '),
          'original': drip,
        });
      }

      records.sort((a, b) {
        final da = DateTime.parse(a['date'].toString());
        final db = DateTime.parse(b['date'].toString());
        final compare = db.compareTo(da);
        if (compare != 0) return compare;
        return (b['id'] as int).compareTo(a['id'] as int);
      });

      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load history: $e';
      });
    }
  }

  Future<void> _openSpray(Map<String, dynamic> record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddSprayPage(
          plotId: widget.plotId,
          plotTitle: widget.plotTitle,
          spray: record['original'] as Map<String, dynamic>,
        ),
      ),
    );
    await _loadRecords();
  }

  Future<void> _openDrip(Map<String, dynamic> record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddDripPage(
          plotId: widget.plotId,
          plotTitle: widget.plotTitle,
          drip: record['original'] as Map<String, dynamic>,
        ),
      ),
    );
    await _loadRecords();
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    final type = record['record_type'].toString().toLowerCase();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Delete $type record?'),
          content: Text(
            'This $type record and its chemical details will be deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    if (record['record_type'] == 'Spray') {
      await AppDatabase.instance.deleteSpray(record['id'] as int);
    } else {
      await AppDatabase.instance.deleteDripApplication(record['id'] as int);
    }

    await _loadRecords();
  }

  Future<void> _openRecord(Map<String, dynamic> record) async {
    if (record['record_type'] == 'Spray') {
      await _openSpray(record);
    } else {
      await _openDrip(record);
    }
  }

  Widget _headerCell(
    String text,
    double flex, {
    IconData? icon,
    TextAlign align = TextAlign.left,
  }) {
    return Expanded(
      flex: (flex * 100).round(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 9),
        child: Row(
          mainAxisAlignment: align == TextAlign.right
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: const Color(0xFF0D47A1)),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                text,
                textAlign: align,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF315B88),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataCell(
    Widget child,
    double flex, {
    TextAlign align = TextAlign.left,
  }) {
    return Expanded(
      flex: (flex * 100).round(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
        child: Align(
          alignment: align == TextAlign.right
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }

  Widget _buildRecordTable(
    List<Map<String, dynamic>> records,
    bool isSpray,
  ) {
    final total = records.fold<double>(
      0,
      (sum, record) => sum + (record['total_cost'] as num).toDouble(),
    );

    if (records.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 24),
        child: Text(
          isSpray
              ? 'No spray records for this plot yet.\n\nUse "Add spray" to create a record.'
              : 'No drip records for this plot yet.\n\nUse "Add drip application" to create a record.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    final waterFlex = 1.05;
    final costFlex = 1.25;
    final actionFlex = 0.9;
    final dateFlex = 1.45;
    final chemicalFlex = 2.8;

    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            color: Color(0xFFE8F2FD),
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            children: [
              _headerCell('Date', dateFlex, icon: Icons.calendar_today_outlined),
              _headerCell('Chemicals', chemicalFlex, icon: Icons.eco_outlined),
              _headerCell(
                isSpray ? 'Water' : 'Area',
                waterFlex,
                icon: isSpray
                    ? Icons.water_drop_outlined
                    : Icons.square_foot_outlined,
              ),
              _headerCell('Cost', costFlex, icon: Icons.currency_rupee, align: TextAlign.right),
              _headerCell('Action', actionFlex, icon: Icons.settings_outlined, align: TextAlign.center),
            ],
          ),
        ),
        ...List.generate(records.length, (index) {
          final record = records[index];
          final date = DateTime.parse(record['date'].toString());
          final quantity = (record['quantity'] as num).toDouble();
          final cost = (record['total_cost'] as num).toDouble();
          final chemicalText = _showDosage
              ? record['chemicals_dosage'].toString()
              : record['chemicals'].toString();

          return Material(
            color: index.isEven ? Colors.white : const Color(0xFFFAFCFF),
            child: InkWell(
              onTap: () => _openRecord(record),
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Color(0xFFDCE8F4)),
                    right: BorderSide(color: Color(0xFFDCE8F4)),
                    bottom: BorderSide(color: Color(0xFFDCE8F4)),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _dataCell(
                      Text(
                        formatDate(date),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      dateFlex,
                    ),
                    _dataCell(
                      Text(
                        chemicalText.isEmpty ? 'No chemical' : chemicalText,
                        maxLines: _showDosage ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      chemicalFlex,
                    ),
                    _dataCell(
                      Text(
                        isSpray
                            ? '${formatNumber(quantity)} L'
                            : '${formatNumber(quantity)} ac',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Colors.grey,
                        ),
                      ),
                      waterFlex,
                    ),
                    _dataCell(
                      Text(
                        '₹${cost.toStringAsFixed(2)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0D47A1),
                        ),
                      ),
                      costFlex,
                      align: TextAlign.right,
                    ),
                    _dataCell(
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Edit',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 24,
                              minHeight: 32,
                            ),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.edit_outlined,
                              color: Color(0xFF315B88),
                              size: 17,
                            ),
                            onPressed: () => _openRecord(record),
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 24,
                              minHeight: 32,
                            ),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                              size: 17,
                            ),
                            onPressed: () => _deleteRecord(record),
                          ),
                        ],
                      ),
                      actionFlex,
                      align: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFE9F7F1),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            border: Border.all(color: const Color(0xFFDCE8F4)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              const Expanded(
                flex: 425,
                child: Text(
                  'Total cost',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              Expanded(
                flex: 125,
                child: Text(
                  '₹${total.toStringAsFixed(2)}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Color(0xFF00796B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleRecords = _records
        .where(
          (record) => _recordTab == 0
              ? record['record_type'] == 'Spray'
              : record['record_type'] == 'Drip',
        )
        .toList();

    final isSpray = _recordTab == 0;

    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.plotTitle),
          bottom: TabBar(
            onTap: (index) => setState(() => _recordTab = index),
            tabs: const [
              Tab(icon: Icon(Icons.science_outlined), text: 'Spray'),
              Tab(icon: Icon(Icons.opacity_outlined), text: 'Drip'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: _showDosage ? 'Hide dosage' : 'Show dosage',
              onPressed: () => setState(() => _showDosage = !_showDosage),
              icon: Icon(
                _showDosage
                    ? Icons.visibility
                    : Icons.visibility_off_outlined,
              ),
            ),
            IconButton(
              tooltip: 'Plot information',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(widget.plotTitle),
                    content: Text(
                      'Plot: ${widget.plotName}\n'
                      'Crop variety: ${widget.cropVariety}',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        floatingActionButton: SafeArea(
          child: FloatingActionButton.extended(
            heroTag: 'add_${isSpray ? 'spray' : 'drip'}_${widget.plotId}',
            backgroundColor:
                isSpray ? const Color(0xFF0D47A1) : Colors.teal.shade700,
            foregroundColor: Colors.white,
            onPressed: () async {
              await AppDatabase.instance.setLastPage(
                widget.plotId,
                isSpray ? 'spray' : 'drip',
              );
              if (!context.mounted) return;

              if (isSpray) {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AddSprayPage(
                      plotId: widget.plotId,
                      plotTitle: widget.plotTitle,
                    ),
                  ),
                );
              } else {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AddDripPage(
                      plotId: widget.plotId,
                      plotTitle: widget.plotTitle,
                    ),
                  ),
                );
              }

              await _loadRecords();
            },
            icon: Icon(isSpray ? Icons.water_drop : Icons.opacity),
            label: Text(isSpray ? 'Add spray' : 'Add drip application'),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(30),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_loadError!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _loadRecords,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadRecords,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 100),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                isSpray
                                    ? 'Spray Records'
                                    : 'Drip Records',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF17395C),
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.teal.shade700,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${visibleRecords.length} records',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.visibility_outlined,
                              size: 16,
                              color: Color(0xFF0D47A1),
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              'Show dosage',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Switch(
                              value: _showDosage,
                              onChanged: (value) =>
                                  setState(() => _showDosage = value),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            const Spacer(),
                            Text(
                              isSpray ? 'Water in L' : 'Area in acres',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _buildRecordTable(visibleRecords, isSpray),
                      ],
                    ),
                  ),
      ),
    );
  }
}

// ============================================================
// ADD / EDIT DRIP APPLICATION
// ============================================================

class AddDripPage extends StatefulWidget {
  const AddDripPage({
    super.key,
    required this.plotId,
    required this.plotTitle,
    this.drip,
  });

  final int plotId;
  final String plotTitle;
  final Map<String, dynamic>? drip;

  @override
  State<AddDripPage> createState() => _AddDripPageState();
}

class _AddDripPageState extends State<AddDripPage> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _acresController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final Map<int, TextEditingController> _dosageControllers = {};

  List<Map<String, dynamic>> _allChemicals = [];
  List<Map<String, dynamic>> _filteredChemicals = [];
  final List<SelectedDripChemical> _selectedChemicals = [];

  DateTime _selectedDate = DateTime.now();
  bool _loading = true;
  bool _saving = false;

  bool get _isEditing => widget.drip != null;

  double get _acres =>
      double.tryParse(_acresController.text.trim()) ?? 0;

  double _chemicalCost(SelectedDripChemical chemical) {
    // If the chemical's price is saved per kg/L (matching the dosage's
    // kg/acre or L/acre scale) the multiplier is 1. If it's saved per
    // gram/ml (or the unit isn't set, for older chemicals) the dosage is
    // converted to gram/acre or ml/acre with a x1000 multiplier.
    final multiplier =
        dripDosageMultiplier(chemical.dosageUnit, chemical.unit);
    return _acres * chemical.dosage * multiplier * chemical.price;
  }

  double get _totalCost {
    return _selectedChemicals.fold<double>(
      0,
      (sum, chemical) => sum + _chemicalCost(chemical),
    );
  }

  @override
  void initState() {
    super.initState();
    _acresController.addListener(_recalculate);
    _searchController.addListener(_filterChemicals);
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _acresController.dispose();
    _notesController.dispose();
    for (final controller in _dosageControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _recalculate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadData() async {
    try {
      final chemicals = await AppDatabase.instance.getChemicals();

      if (widget.drip != null) {
        final drip = widget.drip!;
        _selectedDate = DateTime.parse(drip['drip_date'].toString());
        _acresController.text =
            formatNumber((drip['acres'] as num).toDouble());
        _notesController.text = drip['notes'].toString();

        final rows =
            await AppDatabase.instance.getDripChemicals(drip['id'] as int);

        for (final row in rows) {
          final chemicalId = row['chemical_id'] as int?;
          if (chemicalId == null) continue;

          // The drip_chemicals row only stores the numeric price, not the
          // unit it was priced in (kg/gram/L/ml) — that lives on the
          // chemical itself, so look it up from the current chemicals list.
          final matching = chemicals.where((c) => c['id'] == chemicalId);
          final chemicalUnit =
              matching.isNotEmpty ? (matching.first['unit']?.toString() ?? '') : '';
          final savedDosageUnit = row['dosage_unit']?.toString() ?? '';
          final automaticDosageUnit = dripDosageUnitForChemical(
            chemicalUnit,
            legacyUnit: savedDosageUnit.isNotEmpty ? savedDosageUnit : 'L/acre',
          );

          final selected = SelectedDripChemical(
            id: chemicalId,
            name: row['chemical_name'].toString(),
            price: (row['price_per_unit'] as num).toDouble(),
            unit: chemicalUnit,
            dosage: (row['dosage'] as num).toDouble(),
            dosageUnit: automaticDosageUnit,
          );
          _selectedChemicals.add(selected);
          _createDosageController(selected);
        }
      }

      if (!mounted) return;
      setState(() {
        _allChemicals = chemicals;
        _filteredChemicals = chemicals;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load drip form: $e')),
      );
    }
  }

  void _filterChemicals() {
    final query = _searchController.text.trim().toLowerCase();
    if (!mounted) return;
    setState(() {
      _filteredChemicals = query.isEmpty
          ? _allChemicals
          : _allChemicals.where((chemical) {
              return chemical['name'].toString().toLowerCase().contains(query);
            }).toList();
    });
  }

  bool _isSelected(int chemicalId) {
    return _selectedChemicals.any((chemical) => chemical.id == chemicalId);
  }

  void _createDosageController(SelectedDripChemical chemical) {
    if (_dosageControllers.containsKey(chemical.id)) return;

    final controller = TextEditingController(
      text: chemical.dosage == 0 ? '' : formatNumber(chemical.dosage),
    );

    controller.addListener(() {
      final dosage =
          double.tryParse(controller.text.trim()) ?? 0;
      final matches =
          _selectedChemicals.where((item) => item.id == chemical.id);
      if (matches.isNotEmpty) {
        matches.first.dosage = dosage;
      }
      if (mounted) setState(() {});
    });

    _dosageControllers[chemical.id] = controller;
  }

  void _selectChemical(Map<String, dynamic> row) {
    final id = row['id'] as int;
    if (_isSelected(id)) return;

    final chemicalUnit = row['unit']?.toString() ?? '';
    if (chemicalUnit.isEmpty) {
      _showError('Set the chemical unit in Chemical Database first.');
      return;
    }

    final selected = SelectedDripChemical(
      id: id,
      name: row['name'].toString(),
      price: (row['price'] as num).toDouble(),
      unit: chemicalUnit,
      dosageUnit: dripDosageUnitForChemical(chemicalUnit),
    );

    setState(() => _selectedChemicals.add(selected));
    _createDosageController(selected);
    _searchController.clear();
  }

  void _removeChemical(SelectedDripChemical chemical) {
    final controller = _dosageControllers.remove(chemical.id);
    controller?.dispose();
    setState(() {
      _selectedChemicals.removeWhere((item) => item.id == chemical.id);
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
  }

  Future<void> _save() async {
    if (_saving) return;

    final acres = double.tryParse(_acresController.text.trim());
    if (acres == null || acres <= 0) {
      _showError('Enter a valid acreage greater than 0.');
      return;
    }

    if (_selectedChemicals.isEmpty) {
      _showError('Select at least one chemical.');
      return;
    }

    for (final chemical in _selectedChemicals) {
      if (chemical.unit.isEmpty) {
        _showError(
          'Set the unit for ${chemical.name} in Chemical Database first.',
        );
        return;
      }
      if (chemical.dosage <= 0) {
        _showError(
          'Enter a dosage greater than 0 for ${chemical.name}.',
        );
        return;
      }
    }

    setState(() => _saving = true);

    try {
      if (_isEditing) {
        await AppDatabase.instance.updateDripApplication(
          dripId: widget.drip!['id'] as int,
          plotId: widget.plotId,
          date: _selectedDate,
          acres: acres,
          totalCost: _totalCost,
          notes: _notesController.text.trim(),
          chemicals: _selectedChemicals,
        );
      } else {
        await AppDatabase.instance.addDripApplication(
          plotId: widget.plotId,
          date: _selectedDate,
          acres: acres,
          totalCost: _totalCost,
          notes: _notesController.text.trim(),
          chemicals: _selectedChemicals,
        );
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showError('Could not save drip record.');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit drip application' : 'Add drip application'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
              children: [
                Text(
                  widget.plotTitle,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D47A1),
                  ),
                ),
                const SizedBox(height: 18),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(10),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                    child: Text(formatDate(_selectedDate)),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _acresController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Acreage',
                    hintText: 'Example: 2',
                    suffixText: 'acres',
                    prefixIcon: Icon(Icons.landscape),
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Search chemicals',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D47A1),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: 'Search chemicals',
                    hintText: 'Type chemical name',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: _searchController.clear,
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_filteredChemicals.isNotEmpty)
                  Card(
                    margin: EdgeInsets.zero,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _filteredChemicals.length,
                        itemBuilder: (context, index) {
                          final chemical = _filteredChemicals[index];
                          final id = chemical['id'] as int;
                          final selected = _isSelected(id);
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.science_outlined,
                              color: selected
                                  ? Colors.green
                                  : const Color(0xFF0D47A1),
                            ),
                            title: Text(chemical['name'].toString()),
                            subtitle: Text(
                              (chemical['price'] as num).toDouble() > 0
                                  ? '₹${(chemical['price'] as num).toDouble().toStringAsFixed(2)}${chemical['unit']?.toString().isNotEmpty == true ? ' / ${chemical['unit']}' : ' per unit'}'
                                  : (chemical['unit']?.toString().isNotEmpty == true
                                      ? 'Unit: ${chemical['unit']}'
                                      : 'Price not set'),
                            ),
                            enabled: !selected,
                            onTap: selected
                                ? null
                                : () => _selectChemical(chemical),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                if (_selectedChemicals.isNotEmpty) ...[
                  const Text(
                    'Selected chemicals',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0D47A1),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ..._selectedChemicals.map((chemical) {
                    final controller = _dosageControllers[chemical.id]!;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    chemical.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _removeChemical(chemical),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                            Text(
                              'Saved price: ₹${chemical.price.toStringAsFixed(2)}${chemical.unit.isNotEmpty ? ' / ${chemical.unit}' : ' per unit'}',
                              style: const TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: controller,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Dosage',
                                      hintText: 'Example: 2',
                                      prefixIcon: Icon(Icons.opacity),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Dosage unit (automatic)',
                                      prefixIcon: Icon(Icons.auto_awesome),
                                    ),
                                    child: Text(
                                      chemical.dosageUnit,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Builder(builder: (context) {
                              final multiplier = dripDosageMultiplier(
                                chemical.dosageUnit,
                                chemical.unit,
                              );
                              final multiplierLabel =
                                  multiplier == 1.0 ? '' : '× ${formatNumber(multiplier)} ';
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Cost: ${formatNumber(_acres)} acres × '
                                    '${formatNumber(chemical.dosage)} ${chemical.dosageUnit} '
                                    '$multiplierLabel× ₹${chemical.price.toStringAsFixed(2)} = '
                                    '₹${_chemicalCost(chemical).toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF0D47A1),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    chemical.unit.toLowerCase() == 'ml' ||
                                            chemical.unit.toLowerCase() == 'l'
                                        ? 'Unit ${chemical.unit} → dosage is automatically L/acre.'
                                        : chemical.unit.toLowerCase() == 'gram' ||
                                                chemical.unit.toLowerCase() == 'kg'
                                            ? 'Unit ${chemical.unit} → dosage is automatically kg/acre.'
                                            : 'Set the chemical unit in Chemical Database to enable automatic dosage units.',
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              );
                            }),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 6),
                Card(
                  color: const Color(0xFFE0F2F1),
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Acreage: ${formatNumber(_acres)} acres',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Color(0xFF00695C),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Total cost: ₹${_totalCost.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00695C),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _notesController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Observations or other information',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(
                      _saving
                          ? 'Saving...'
                          : _isEditing
                              ? 'Save changes'
                              : 'Save drip application',
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ============================================================
// ADD / EDIT SPRAY
// ============================================================

class AddSprayPage extends StatefulWidget {
  const AddSprayPage({
    super.key,
    required this.plotId,
    required this.plotTitle,
    this.spray,
  });

  final int plotId;
  final String plotTitle;
  final Map<String, dynamic>? spray;

  @override
  State<AddSprayPage> createState() => _AddSprayPageState();
}

class _AddSprayPageState extends State<AddSprayPage> {
  final TextEditingController _searchController =
      TextEditingController();

  final TextEditingController _waterController =
      TextEditingController();

  final TextEditingController _notesController =
      TextEditingController();

  final Map<int, TextEditingController> _dosageControllers = {};

  List<Map<String, dynamic>> _allChemicals = [];
  List<Map<String, dynamic>> _filteredChemicals = [];
  final List<SelectedChemical> _selectedChemicals = [];

  DateTime _selectedDate = DateTime.now();

  bool _loading = true;
  bool _saving = false;

  bool get _isEditing => widget.spray != null;

  double get _water {
    return double.tryParse(
          _waterController.text.trim(),
        ) ??
        0;
  }

  double get _totalCost {
    double total = 0;
    for (final chemical in _selectedChemicals) {
      total += _water * chemical.dosage * chemical.price;
    }
    return total;
  }

  @override
  void initState() {
    super.initState();

    _waterController.addListener(_recalculate);
    _searchController.addListener(_filterChemicals);

    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _waterController.dispose();
    _notesController.dispose();

    for (final controller in _dosageControllers.values) {
      controller.dispose();
    }

    super.dispose();
  }

  void _recalculate() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadData() async {
    try {
      await _loadDataInner();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load spray form: $e')),
      );
    }
  }

  Future<void> _loadDataInner() async {
    final chemicals = await AppDatabase.instance.getChemicals();

    if (widget.spray != null) {
      final spray = widget.spray!;

      _selectedDate = DateTime.parse(
        spray['spray_date'].toString(),
      );

      _waterController.text = formatNumber(
        (spray['water'] as num).toDouble(),
      );

      _notesController.text = spray['notes'].toString();

      final sprayChemicals =
          await AppDatabase.instance.getSprayChemicals(
        spray['id'] as int,
      );

      for (final row in sprayChemicals) {
        final chemicalId =
            row['chemical_id'] as int?;

        if (chemicalId == null) {
          continue;
        }

        final matchingChemical = chemicals.where(
          (chemical) => chemical['id'] == chemicalId,
        );
        final savedUnit = matchingChemical.isNotEmpty
            ? matchingChemical.first['unit']?.toString() ?? ''
            : '';

        final selected = SelectedChemical(
          id: chemicalId,
          name: row['chemical_name'].toString(),
          price: (row['price_per_unit'] as num).toDouble(),
          unit: savedUnit,
          dosage: (row['dosage'] as num).toDouble(),
        );

        _selectedChemicals.add(selected);

        _createDosageController(selected);
      }
    }

    if (!mounted) return;

    setState(() {
      _allChemicals = chemicals;
      _filteredChemicals = chemicals;
      _loading = false;
    });
  }

  void _filterChemicals() {
    final query = _searchController.text.trim().toLowerCase();

    setState(() {
      if (query.isEmpty) {
        _filteredChemicals = _allChemicals;
      } else {
        _filteredChemicals = _allChemicals.where((chemical) {
          final name = chemical['name'].toString().toLowerCase();
          return name.contains(query);
        }).toList();
      }
    });
  }

  bool _isSelected(int chemicalId) {
    return _selectedChemicals.any(
      (chemical) => chemical.id == chemicalId,
    );
  }

  void _createDosageController(
    SelectedChemical chemical,
  ) {
    if (_dosageControllers.containsKey(chemical.id)) {
      return;
    }

    final controller = TextEditingController(
      text: chemical.dosage == 0
          ? ''
          : formatNumber(chemical.dosage),
    );

    controller.addListener(() {
      final dosage = double.tryParse(
            controller.text.trim(),
          ) ??
          0;

      final selected = _selectedChemicals.cast<SelectedChemical?>().firstWhere(
            (item) => item?.id == chemical.id,
            orElse: () => null,
          );

      if (selected != null) {
        selected.dosage = dosage;
      }

      if (mounted) {
        setState(() {});
      }
    });

    _dosageControllers[chemical.id] = controller;
  }

  void _selectChemical(Map<String, dynamic> row) {
    final id = row['id'] as int;

    if (_isSelected(id)) {
      return;
    }

    final selected = SelectedChemical(
      id: id,
      name: row['name'].toString(),
      price: (row['price'] as num).toDouble(),
      unit: row['unit']?.toString() ?? '',
    );

    setState(() {
      _selectedChemicals.add(selected);
    });

    _createDosageController(selected);

    _searchController.clear();
  }

  void _removeChemical(SelectedChemical chemical) {
    final controller = _dosageControllers.remove(chemical.id);
    controller?.dispose();

    setState(() {
      _selectedChemicals.removeWhere(
        (item) => item.id == chemical.id,
      );
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked == null) return;

    setState(() {
      _selectedDate = picked;
    });
  }

  Future<void> _save() async {
    if (_saving) return;

    final water = double.tryParse(
      _waterController.text.trim(),
    );

    if (water == null || water < 0) {
      _showError('Enter a valid water quantity.');
      return;
    }

    if (_selectedChemicals.isEmpty) {
      _showError('Select at least one chemical.');
      return;
    }

    for (final chemical in _selectedChemicals) {
      if (chemical.dosage <= 0) {
        _showError(
          'Enter a dosage greater than 0 for ${chemical.name}.',
        );
        return;
      }
    }

    setState(() {
      _saving = true;
    });

    try {
      if (_isEditing) {
        await AppDatabase.instance.updateSpray(
          sprayId: widget.spray!['id'] as int,
          plotId: widget.plotId,
          date: _selectedDate,
          water: water,
          totalCost: _totalCost,
          notes: _notesController.text.trim(),
          chemicals: _selectedChemicals,
        );
      } else {
        await AppDatabase.instance.addSpray(
          plotId: widget.plotId,
          date: _selectedDate,
          water: water,
          totalCost: _totalCost,
          notes: _notesController.text.trim(),
          chemicals: _selectedChemicals,
        );
      }

      if (!mounted) return;

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _saving = false;
      });

      _showError('Could not save spray record.');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditing ? 'Edit spray' : 'Add spray',
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                16,
                16,
                16,
                30,
              ),
              children: [
                Text(
                  widget.plotTitle,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D47A1),
                  ),
                ),
                const SizedBox(height: 18),

                // DATE
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(10),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      formatDate(_selectedDate),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // WATER
                TextField(
                  controller: _waterController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Water quantity',
                    hintText: 'Example: 500',
                    suffixText: 'L',
                    prefixIcon: Icon(Icons.water_drop),
                  ),
                ),

                const SizedBox(height: 22),

                const Text(
                  'Search chemicals',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D47A1),
                  ),
                ),

                const SizedBox(height: 8),

                // CHEMICAL SEARCH
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: 'Search chemicals',
                    hintText: 'Type chemical name, e.g. Tit',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                            },
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),

                const SizedBox(height: 8),

                if (_filteredChemicals.isNotEmpty)
                  Card(
                    margin: EdgeInsets.zero,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 220,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _filteredChemicals.length,
                        itemBuilder: (context, index) {
                          final chemical =
                              _filteredChemicals[index];

                          final id = chemical['id'] as int;
                          final selected = _isSelected(id);

                          return ListTile(
                            dense: true,
                            leading: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.science_outlined,
                              color: selected
                                  ? Colors.green
                                  : const Color(0xFF0D47A1),
                            ),
                            title: Text(
                              chemical['name'].toString(),
                            ),
                            subtitle: Text(
                              (chemical['price'] as num).toDouble() > 0
                                  ? '₹${(chemical['price'] as num).toDouble().toStringAsFixed(2)}${chemical['unit']?.toString().isNotEmpty == true ? ' / ${chemical['unit']}' : ' per unit'}'
                                  : (chemical['unit']?.toString().isNotEmpty == true
                                      ? 'Unit: ${chemical['unit']}'
                                      : 'Price not set'),
                            ),
                            enabled: !selected,
                            onTap: selected
                                ? null
                                : () => _selectChemical(
                                      chemical,
                                    ),
                          );
                        },
                      ),
                    ),
                  ),

                const SizedBox(height: 18),

                if (_selectedChemicals.isNotEmpty) ...[
                  const Text(
                    'Selected chemicals',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0D47A1),
                    ),
                  ),
                  const SizedBox(height: 10),

                  ..._selectedChemicals.map(
                    (chemical) {
                      final dosageController =
                          _dosageControllers[chemical.id]!;

                      return Card(
                        margin: const EdgeInsets.only(
                          bottom: 10,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      chemical.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove',
                                    onPressed: () =>
                                        _removeChemical(
                                      chemical,
                                    ),
                                    icon: const Icon(
                                      Icons.close,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                'Saved price: ₹${chemical.price.toStringAsFixed(2)}${chemical.unit.isNotEmpty ? ' / ${chemical.unit}' : ' per unit'}',
                                style: const TextStyle(
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: dosageController,
                                keyboardType:
                                    const TextInputType
                                        .numberWithOptions(
                                  decimal: true,
                                ),
                                decoration:
                                    const InputDecoration(
                                  labelText: 'Dosage',
                                  hintText: 'Enter dosage',
                                  prefixIcon:
                                      Icon(Icons.opacity),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Cost: ${formatNumber(_water)} × ${formatNumber(chemical.dosage)} × ₹${chemical.price.toStringAsFixed(2)} = ₹${(_water * chemical.dosage * chemical.price).toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0D47A1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],

                const SizedBox(height: 6),

                // TOTAL COST
                Card(
                  color: const Color(0xFFE3F2FD),
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Water: ${formatNumber(_water)} L',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Color(0xFF0D47A1),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Total cost: ₹${_totalCost.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0D47A1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // NOTES
                TextField(
                  controller: _notesController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText:
                        'Observations or other information',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes),
                  ),
                ),

                const SizedBox(height: 24),

                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(
                      _saving
                          ? 'Saving...'
                          : _isEditing
                              ? 'Save changes'
                              : 'Save spray',
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ============================================================
