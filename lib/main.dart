import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.instance.db;
  runApp(const AgriSprayApp());
}

class AgriSprayApp extends StatelessWidget {
  const AgriSprayApp({super.key});

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF0D47A1);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Agri Spray Offline',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF42A5F5)),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF42A5F5),
          foregroundColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: blue, width: 2),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class AppDb {
  AppDb._();
  static final instance = AppDb._();
  Database? _database;

  Future<Database> get db async {
    if (_database != null) return _database!;
    final dir = await getDatabasesPath();
    final file = p.join(dir, 'agri_spray_offline.db');
    _database = await openDatabase(
      file,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS chemicals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            price REAL NOT NULL DEFAULT 0
          )
        ''');
        await _newTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Never delete/reset the existing database or chemical records.
        if (oldVersion < 3) await _newTables(db);
      },
    );
    return _database!;
  }

  Future<void> _newTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        plot_name TEXT NOT NULL,
        crop_variety TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sprays (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        plot_id INTEGER NOT NULL,
        spray_date TEXT NOT NULL,
        water REAL NOT NULL,
        total_cost REAL NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS spray_chemicals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        spray_id INTEGER NOT NULL,
        chemical_id INTEGER,
        chemical_name TEXT NOT NULL,
        dosage REAL NOT NULL,
        price_per_unit REAL NOT NULL,
        cost REAL NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS drip_applications (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        plot_id INTEGER NOT NULL,
        application_date TEXT NOT NULL,
        acres REAL NOT NULL,
        total_cost REAL NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS drip_chemicals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        drip_id INTEGER NOT NULL,
        chemical_id INTEGER,
        chemical_name TEXT NOT NULL,
        dosage REAL NOT NULL,
        dosage_unit TEXT NOT NULL,
        price_per_unit REAL NOT NULL,
        cost REAL NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sprays_plot ON sprays(plot_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spray_chemicals ON spray_chemicals(spray_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_drip_applications_plot ON drip_applications(plot_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_drip_chemicals ON drip_chemicals(drip_id)',
    );
  }

  Future<List<Map<String, dynamic>>> chemicals() async =>
      (await db).query('chemicals', orderBy: 'name COLLATE NOCASE');

  Future<void> addChemical(String name, double price) async {
    await (await db).insert('chemicals', {'name': name.trim(), 'price': price});
  }

  Future<void> editChemical(int id, String name, double price) async {
    await (await db).update(
      'chemicals',
      {'name': name.trim(), 'price': price},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deleteChemical(int id) async {
    await (await db).delete('chemicals', where: 'id=?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> plots() async =>
      (await db).query('plots', orderBy: 'id DESC');

  Future<void> addPlot(String title, String plot, String crop) async {
    await (await db).insert('plots', {
      'title': title.trim(),
      'plot_name': plot.trim(),
      'crop_variety': crop.trim(),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> editPlot(
    int id,
    String title,
    String plot,
    String crop,
  ) async {
    await (await db).update(
      'plots',
      {
        'title': title.trim(),
        'plot_name': plot.trim(),
        'crop_variety': crop.trim(),
      },
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlot(int id) async {
    final database = await db;
    await database.transaction((tx) async {
      final rows = await tx.query(
        'sprays',
        columns: ['id'],
        where: 'plot_id=?',
        whereArgs: [id],
      );
      for (final r in rows) {
        await tx.delete(
          'spray_chemicals',
          where: 'spray_id=?',
          whereArgs: [r['id']],
        );
      }
      await tx.delete('sprays', where: 'plot_id=?', whereArgs: [id]);
      await tx.delete('plots', where: 'id=?', whereArgs: [id]);
    });
  }

  Future<List<Map<String, dynamic>>> sprays(int plotId) async =>
      (await db).query(
        'sprays',
        where: 'plot_id=?',
        whereArgs: [plotId],
        orderBy: 'spray_date DESC, id DESC',
      );

  Future<List<Map<String, dynamic>>> sprayChemicals(int sprayId) async =>
      (await db).query(
        'spray_chemicals',
        where: 'spray_id=?',
        whereArgs: [sprayId],
        orderBy: 'id',
      );

  Future<int> saveSpray({
    int? id,
    required int plotId,
    required DateTime date,
    required double water,
    required double totalCost,
    required String notes,
    required List<ChosenChemical> chemicals,
  }) async {
    final database = await db;
    return database.transaction((tx) async {
      if (id != null) {
        await tx.update(
          'sprays',
          {
            'plot_id': plotId,
            'spray_date': date.toIso8601String(),
            'water': water,
            'total_cost': totalCost,
            'notes': notes.trim(),
          },
          where: 'id=?',
          whereArgs: [id],
        );
        await tx.delete(
          'spray_chemicals',
          where: 'spray_id=?',
          whereArgs: [id],
        );
      } else {
        id = await tx.insert('sprays', {
          'plot_id': plotId,
          'spray_date': date.toIso8601String(),
          'water': water,
          'total_cost': totalCost,
          'notes': notes.trim(),
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      for (final c in chemicals) {
        await tx.insert('spray_chemicals', {
          'spray_id': id,
          'chemical_id': c.id,
          'chemical_name': c.name,
          'dosage': c.dosage,
          'price_per_unit': c.price,
          'cost': c.dosage * c.price,
        });
      }
      return id!;
    });
  }

  Future<void> deleteSpray(int id) async {
    final database = await db;
    await database.transaction((tx) async {
      await tx.delete('spray_chemicals', where: 'spray_id=?', whereArgs: [id]);
      await tx.delete('sprays', where: 'id=?', whereArgs: [id]);
    });
  }
}

class ChosenChemical {
  ChosenChemical({
    required this.id,
    required this.name,
    required this.price,
    this.dosage = 0,
  });

  final int id;
  final String name;
  final double price;
  double dosage;

  double get cost => dosage * price;
}

String money(double v) => v.toStringAsFixed(2);

String numText(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

String dateText(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  final pages = const [
    DashboardPage(),
    HistoryPage(),
    ChemicalsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (v) => setState(() => index = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Chemicals',
          ),
        ],
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agri Spray Offline')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.agriculture, size: 82, color: Color(0xFF0D47A1)),
          const SizedBox(height: 12),
          const Text(
            'Agri Spray Offline',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0D47A1),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Offline spray records, chemical prices and cost calculation.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 30),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history, color: Color(0xFF0D47A1)),
              title: const Text('Spray History'),
              subtitle: const Text('Manage plots, crops and spray records.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryPage()),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.science, color: Color(0xFF0D47A1)),
              title: const Text('Chemical Database'),
              subtitle: const Text('Add, edit or delete chemicals and prices.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ChemicalsPage()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChemicalsPage extends StatefulWidget {
  const ChemicalsPage({super.key});

  @override
  State<ChemicalsPage> createState() => _ChemicalsPageState();
}

class _ChemicalsPageState extends State<ChemicalsPage> {
  List<Map<String, dynamic>> data = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final rows = await AppDb.instance.chemicals();
    if (!mounted) return;
    setState(() {
      data = rows;
      loading = false;
    });
  }

  Future<void> editDialog([Map<String, dynamic>? row]) async {
    final name = TextEditingController(text: row?['name']?.toString() ?? '');
    final price = TextEditingController(
      text: row == null ? '' : numText((row['price'] as num).toDouble()),
    );

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(row == null ? 'Add chemical' : 'Edit chemical'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Chemical name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price per unit (₹)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final n = name.text.trim();
              final pr = double.tryParse(price.text.trim());
              if (n.isEmpty || pr == null || pr < 0) return;

              if (row == null) {
                await AppDb.instance.addChemical(n, pr);
              } else {
                await AppDb.instance.editChemical(row['id'] as int, n, pr);
              }

              if (!mounted) return;
              Navigator.pop(dialogContext);
              load();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    name.dispose();
    price.dispose();
  }

  Future<void> remove(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete chemical?'),
        content: Text('Delete "${row['name']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteChemical(row['id'] as int);
      load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chemical Database')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: editDialog,
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add chemical'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : data.isEmpty
              ? const Center(child: Text('No chemicals saved yet.'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                  itemCount: data.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final r = data[i];
                    final price = (r['price'] as num).toDouble();
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.science),
                        ),
                        title: Text(
                          r['name'].toString(),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text('₹${money(price)} per unit'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') editDialog(r);
                            if (v == 'delete') remove(r);
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
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> data = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final rows = await AppDb.instance.plots();
    if (!mounted) return;
    setState(() {
      data = rows;
      loading = false;
    });
  }

  Future<void> plotDialog([Map<String, dynamic>? row]) async {
    final title = TextEditingController(text: row?['title']?.toString() ?? '');
    final plot = TextEditingController(
      text: row?['plot_name']?.toString() ?? '',
    );
    final crop = TextEditingController(
      text: row?['crop_variety']?.toString() ?? '',
    );

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(row == null ? 'Add plot / crop' : 'Edit plot / crop'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Farm 1 - Cotton',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: plot,
                decoration: const InputDecoration(
                  labelText: 'Plot name or number',
                  hintText: 'Plot 2',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: crop,
                decoration: const InputDecoration(
                  labelText: 'Crop variety',
                  hintText: 'Cotton',
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
              if (title.text.trim().isEmpty ||
                  plot.text.trim().isEmpty ||
                  crop.text.trim().isEmpty) {
                return;
              }

              if (row == null) {
                await AppDb.instance.addPlot(
                  title.text,
                  plot.text,
                  crop.text,
                );
              } else {
                await AppDb.instance.editPlot(
                  row['id'] as int,
                  title.text,
                  plot.text,
                  crop.text,
                );
              }

              if (!mounted) return;
              Navigator.pop(dialogContext);
              load();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    title.dispose();
    plot.dispose();
    crop.dispose();
  }

  Future<void> remove(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete plot / crop?'),
        content: const Text(
          'All spray records inside this plot will also be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await AppDb.instance.deletePlot(row['id'] as int);
      load();
    }
  }

  void open(Map<String, dynamic> row) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlotPage(
          plotId: row['id'] as int,
          title: row['title'].toString(),
          plot: row['plot_name'].toString(),
          crop: row['crop_variety'].toString(),
        ),
      ),
    ).then((_) => load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Spray History')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: plotDialog,
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add plot / crop'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : data.isEmpty
              ? const Center(child: Text('No plots saved yet.'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                  itemCount: data.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final row = data[i];
                    return Card(
                      child: ListTile(
                        title: Text(
                          row['title'].toString(),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0D47A1),
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'open') open(row);
                            if (v == 'edit') plotDialog(row);
                            if (v == 'delete') remove(row);
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
                        onTap: () => open(row),
                      ),
                    );
                  },
                ),
    );
  }
}

class PlotPage extends StatefulWidget {
  const PlotPage({
    super.key,
    required this.plotId,
    required this.title,
    required this.plot,
    required this.crop,
  });

  final int plotId;
  final String title;
  final String plot;
  final String crop;

  @override
  State<PlotPage> createState() => _PlotPageState();
}

class _PlotPageState extends State<PlotPage> {
  List<Map<String, dynamic>> rows = [];
  List<String> combinations = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final sprays = await AppDb.instance.sprays(widget.plotId);
    final combos = <String>[];

    for (final s in sprays) {
      final cs = await AppDb.instance.sprayChemicals(s['id'] as int);
      combos.add(cs.map((c) => c['chemical_name'].toString()).join(' + '));
    }

    if (!mounted) return;
    setState(() {
      rows = sprays;
      combinations = combos;
      loading = false;
    });
  }

  void edit(Map<String, dynamic> row) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SprayFormPage(
          plotId: widget.plotId,
          plotTitle: widget.title,
          spray: row,
        ),
      ),
    ).then((_) => load());
  }

  void add() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SprayFormPage(
          plotId: widget.plotId,
          plotTitle: widget.title,
        ),
      ),
    ).then((_) => load());
  }

  Future<void> remove(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete spray record?'),
        content: const Text('This record will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteSpray(id);
      load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(widget.title),
                content: Text(
                  'Plot: ${widget.plot}\nCrop variety: ${widget.crop}',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: add,
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add spray'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : rows.isEmpty
              ? const Center(child: Text('No spray records yet.'))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 100),
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(
                      const Color(0xFFE3F2FD),
                    ),
                    columns: const [
                      DataColumn(label: Text('No.')),
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Chemical combination')),
                      DataColumn(label: Text('Water')),
                      DataColumn(label: Text('Cost')),
                      DataColumn(label: Text('Notes')),
                    ],
                    rows: List.generate(rows.length, (i) {
                      final r = rows[i];
                      final d = DateTime.parse(r['spray_date'].toString());
                      return DataRow(
                        onSelectChanged: (_) => edit(r),
                        cells: [
                          DataCell(Text('${i + 1}')),
                          DataCell(Text(dateText(d))),
                          DataCell(
                            SizedBox(
                              width: 240,
                              child: Text(combinations[i]),
                            ),
                          ),
                          DataCell(
                            Text('${numText((r['water'] as num).toDouble())} L'),
                          ),
                          DataCell(
                            Text(
                              '₹${money((r['total_cost'] as num).toDouble())}',
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 220,
                              child: Text(
                                r['notes'].toString().isEmpty
                                    ? '-'
                                    : r['notes'].toString(),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
    );
  }
}

class SprayFormPage extends StatefulWidget {
  const SprayFormPage({
    super.key,
    required this.plotId,
    required this.plotTitle,
    this.spray,
  });

  final int plotId;
  final String plotTitle;
  final Map<String, dynamic>? spray;

  @override
  State<SprayFormPage> createState() => _SprayFormPageState();
}

class _SprayFormPageState extends State<SprayFormPage> {
  final search = TextEditingController();
  final water = TextEditingController();
  final notes = TextEditingController();
  final dosage = <int, TextEditingController>{};

  List<Map<String, dynamic>> all = [];
  List<Map<String, dynamic>> matches = [];
  final selected = <ChosenChemical>[];
  DateTime date = DateTime.now();
  bool loading = true;
  bool saving = false;

  double get total => selected.fold(0, (sum, c) => sum + c.cost);

  @override
  void initState() {
    super.initState();
    search.addListener(filter);
    water.addListener(rebuild);
    load();
  }

  @override
  void dispose() {
    search.dispose();
    water.dispose();
    notes.dispose();
    for (final c in dosage.values) c.dispose();
    super.dispose();
  }

  void rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    all = await AppDb.instance.chemicals();
    matches = List.of(all);

    if (widget.spray != null) {
      final s = widget.spray!;
      date = DateTime.parse(s['spray_date'].toString());
      water.text = numText((s['water'] as num).toDouble());
      notes.text = s['notes'].toString();

      final cs = await AppDb.instance.sprayChemicals(s['id'] as int);
      for (final c in cs) {
        final id = c['chemical_id'] as int?;
        if (id == null) continue;

        final chosen = ChosenChemical(
          id: id,
          name: c['chemical_name'].toString(),
          price: (c['price_per_unit'] as num).toDouble(),
          dosage: (c['dosage'] as num).toDouble(),
        );
        selected.add(chosen);
        makeDosageController(chosen);
      }
    }

    if (!mounted) return;
    setState(() => loading = false);
  }

  void filter() {
    final q = search.text.trim().toLowerCase();
    setState(() {
      matches = q.isEmpty
          ? List.of(all)
          : all.where(
              (r) => r['name'].toString().toLowerCase().contains(q),
            ).toList();
    });
  }

  bool has(int id) => selected.any((c) => c.id == id);

  void makeDosageController(ChosenChemical c) {
    if (dosage.containsKey(c.id)) return;

    final controller = TextEditingController(
      text: c.dosage == 0 ? '' : numText(c.dosage),
    );

    controller.addListener(() {
      c.dosage = double.tryParse(controller.text.trim()) ?? 0;
      if (mounted) setState(() {});
    });

    dosage[c.id] = controller;
  }

  void choose(Map<String, dynamic> r) {
    final id = r['id'] as int;
    if (has(id)) return;

    final c = ChosenChemical(
      id: id,
      name: r['name'].toString(),
      price: (r['price'] as num).toDouble(),
    );

    setState(() => selected.add(c));
    makeDosageController(c);
    search.clear();
  }

  void unchoose(ChosenChemical c) {
    dosage.remove(c.id)?.dispose();
    setState(() => selected.removeWhere((x) => x.id == c.id));
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => date = d);
  }

  Future<void> save() async {
    if (saving) return;

    final w = double.tryParse(water.text.trim());
    if (w == null || w < 0) {
      error('Enter a valid water quantity.');
      return;
    }
    if (selected.isEmpty) {
      error('Select at least one chemical.');
      return;
    }
    for (final c in selected) {
      if (c.dosage <= 0) {
        error('Enter a dosage greater than 0 for ${c.name}.');
        return;
      }
    }

    setState(() => saving = true);

    await AppDb.instance.saveSpray(
      id: widget.spray?['id'] as int?,
      plotId: widget.plotId,
      date: date,
      water: w,
      totalCost: total,
      notes: notes.text,
      chemicals: selected,
    );

    if (!mounted) return;
    Navigator.pop(context);
  }

  void error(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.spray == null ? 'Add spray' : 'Edit spray'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
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
                  onTap: pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                    child: Text(dateText(date)),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: water,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Water quantity',
                    suffixText: 'L',
                    prefixIcon: Icon(Icons.water_drop),
                  ),
                ),
                const SizedBox(height: 20),
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
                  controller: search,
                  decoration: InputDecoration(
                    labelText: 'Search chemicals',
                    hintText: 'Type Tit, for example',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: search.clear,
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                if (matches.isNotEmpty)
                  Card(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (_, i) {
                          final r = matches[i];
                          final id = r['id'] as int;
                          final already = has(id);
                          return ListTile(
                            leading: Icon(
                              already
                                  ? Icons.check_circle
                                  : Icons.science_outlined,
                              color: already
                                  ? Colors.green
                                  : const Color(0xFF0D47A1),
                            ),
                            title: Text(r['name'].toString()),
                            subtitle: Text(
                              '₹${money((r['price'] as num).toDouble())} per unit',
                            ),
                            enabled: !already,
                            onTap: already ? null : () => choose(r),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                ...selected.map(
                  (c) => Card(
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
                                  c.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () => unchoose(c),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                          Text(
                            'Saved price: ₹${money(c.price)} per unit',
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: dosage[c.id],
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Dosage',
                              prefixIcon: Icon(Icons.opacity),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Chemical cost: ₹${money(c.cost)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0D47A1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Card(
                  color: const Color(0xFFE3F2FD),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Water: ${numText(double.tryParse(water.text) ?? 0)} L'),
                        const SizedBox(height: 8),
                        Text(
                          'Total cost: ₹${money(total)}',
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
                const SizedBox(height: 16),
                TextField(
                  controller: notes,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Observations or other information',
                    prefixIcon: Icon(Icons.notes),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: saving ? null : save,
                    icon: saving
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
                      saving
                          ? 'Saving...'
                          : widget.spray == null
                              ? 'Save spray'
                              : 'Save changes',
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
