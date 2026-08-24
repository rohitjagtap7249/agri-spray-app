import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDatabase.instance.database;
  runApp(const AgriSprayOfflineApp());
}

class AgriSprayOfflineApp extends StatelessWidget {
  const AgriSprayOfflineApp({super.key});

  @override
  Widget build(BuildContext context) {
    const skyBlue = Color(0xFF42A5F5);
    const darkBlue = Color(0xFF0D47A1);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Agri Spray Offline',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: skyBlue,
          primary: darkBlue,
          secondary: skyBlue,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: skyBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: darkBlue,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 48),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.grey),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
              color: darkBlue,
              width: 2,
            ),
          ),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
// DATABASE
// ============================================================

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String _databaseName = 'agri_spray_offline.db';

  // Version 2 introduces plots, sprays and spray chemicals.
  // Existing chemical data is preserved.
  static const int _databaseVersion = 2;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _openDatabase();
    return _database!;
  }

  Future<Database> _openDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = p.join(databasesPath, _databaseName);

    return openDatabase(
      path,
      version: _databaseVersion,
      onCreate: (db, version) async {
        // IMPORTANT:
        // We do not recreate/reset the chemical table here.
        // This is the first creation of the database, so create it.
        await db.execute('''
          CREATE TABLE IF NOT EXISTS chemicals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            price REAL NOT NULL DEFAULT 0
          )
        ''');

        await _createNewTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Never delete the database.
        // Never drop the chemicals table.
        //
        // The existing chemical records remain untouched.
        if (oldVersion < 2) {
          await _createNewTables(db);
        }
      },
    );
  }

  Future<void> _createNewTables(Database db) async {
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
        created_at TEXT NOT NULL,
        FOREIGN KEY (plot_id) REFERENCES plots(id)
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
        cost REAL NOT NULL,
        FOREIGN KEY (spray_id) REFERENCES sprays(id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sprays_plot_id
      ON sprays(plot_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spray_chemicals_spray_id
      ON spray_chemicals(spray_id)
    ''');
  }

  // ------------------------------------------------------------
  // CHEMICALS
  // ------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getChemicals() async {
    final db = await database;

    return db.query(
      'chemicals',
      orderBy: 'name COLLATE NOCASE ASC',
    );
  }

  Future<void> addChemical({
    required String name,
    required double price,
  }) async {
    final db = await database;

    await db.insert('chemicals', {
      'name': name.trim(),
      'price': price,
    });
  }

  Future<void> updateChemical({
    required int id,
    required String name,
    required double price,
  }) async {
    final db = await database;

    await db.update(
      'chemicals',
      {
        'name': name.trim(),
        'price': price,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteChemical(int id) async {
    final db = await database;

    // We intentionally do not delete old spray_chemicals records.
    // Historical sprays contain their own chemical name and price snapshot.
    await db.delete(
      'chemicals',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ------------------------------------------------------------
  // PLOTS
  // ------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getPlots() async {
    final db = await database;

    return db.query(
      'plots',
      orderBy: 'id DESC',
    );
  }

  Future<int> addPlot({
    required String title,
    required String plotName,
    required String cropVariety,
  }) async {
    final db = await database;

    return db.insert('plots', {
      'title': title.trim(),
      'plot_name': plotName.trim(),
      'crop_variety': cropVariety.trim(),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> updatePlot({
    required int id,
    required String title,
    required String plotName,
    required String cropVariety,
  }) async {
    final db = await database;

    await db.update(
      'plots',
      {
        'title': title.trim(),
        'plot_name': plotName.trim(),
        'crop_variety': cropVariety.trim(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlot(int id) async {
    final db = await database;

    await db.transaction((txn) async {
      final sprays = await txn.query(
        'sprays',
        columns: ['id'],
        where: 'plot_id = ?',
        whereArgs: [id],
      );

      for (final spray in sprays) {
        final sprayId = spray['id'] as int;

        await txn.delete(
          'spray_chemicals',
          where: 'spray_id = ?',
          whereArgs: [sprayId],
        );
      }

      await txn.delete(
        'sprays',
        where: 'plot_id = ?',
        whereArgs: [id],
      );

      await txn.delete(
        'plots',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  // ------------------------------------------------------------
  // SPRAYS
  // ------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getSpraysForPlot(int plotId) async {
    final db = await database;

    return db.query(
      'sprays',
      where: 'plot_id = ?',
      whereArgs: [plotId],
      orderBy: 'spray_date DESC, id DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getSprayChemicals(
    int sprayId,
  ) async {
    final db = await database;

    return db.query(
      'spray_chemicals',
      where: 'spray_id = ?',
      whereArgs: [sprayId],
      orderBy: 'id ASC',
    );
  }

  Future<int> addSpray({
    required int plotId,
    required DateTime date,
    required double water,
    required double totalCost,
    required String notes,
    required List<SelectedChemical> chemicals,
  }) async {
    final db = await database;

    return db.transaction((txn) async {
      final sprayId = await txn.insert('sprays', {
        'plot_id': plotId,
        'spray_date': date.toIso8601String(),
        'water': water,
        'total_cost': totalCost,
        'notes': notes.trim(),
        'created_at': DateTime.now().toIso8601String(),
      });

      for (final chemical in chemicals) {
        final dosage = chemical.dosage;
        final price = chemical.price;

        await txn.insert('spray_chemicals', {
          'spray_id': sprayId,
          'chemical_id': chemical.id,
          'chemical_name': chemical.name,
          'dosage': dosage,
          'price_per_unit': price,
          'cost': dosage * price,
        });
      }

      return sprayId;
    });
  }

  Future<void> updateSpray({
    required int sprayId,
    required int plotId,
    required DateTime date,
    required double water,
    required double totalCost,
    required String notes,
    required List<SelectedChemical> chemicals,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.update(
        'sprays',
        {
          'plot_id': plotId,
          'spray_date': date.toIso8601String(),
          'water': water,
          'total_cost': totalCost,
          'notes': notes.trim(),
        },
        where: 'id = ?',
        whereArgs: [sprayId],
      );

      await txn.delete(
        'spray_chemicals',
        where: 'spray_id = ?',
        whereArgs: [sprayId],
      );

      for (final chemical in chemicals) {
        await txn.insert('spray_chemicals', {
          'spray_id': sprayId,
          'chemical_id': chemical.id,
          'chemical_name': chemical.name,
          'dosage': chemical.dosage,
          'price_per_unit': chemical.price,
          'cost': chemical.dosage * chemical.price,
        });
      }
    });
  }

  Future<void> deleteSpray(int sprayId) async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.delete(
        'spray_chemicals',
        where: 'spray_id = ?',
        whereArgs: [sprayId],
      );

      await txn.delete(
        'sprays',
        where: 'id = ?',
        whereArgs: [sprayId],
      );
    });
  }
}

// ============================================================
// MODELS
// ============================================================

class SelectedChemical {
  SelectedChemical({
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

// ============================================================
// HOME
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    DashboardPage(),
    PlotHistoryPage(),
    ChemicalsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
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

// ============================================================
// DASHBOARD
// ============================================================

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agri Spray Offline'),
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
  List<Map<String, dynamic>> _chemicals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChemicals();
  }

  Future<void> _loadChemicals() async {
    final chemicals = await AppDatabase.instance.getChemicals();

    if (!mounted) return;

    setState(() {
      _chemicals = chemicals;
      _loading = false;
    });
  }

  Future<void> _showChemicalDialog({
    Map<String, dynamic>? chemical,
  }) async {
    final nameController = TextEditingController(
      text: chemical == null ? '' : chemical['name'].toString(),
    );

    final priceController = TextEditingController(
      text: chemical == null
          ? ''
          : _formatNumber(
              (chemical['price'] as num).toDouble(),
            ),
    );

    final isEditing = chemical != null;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            isEditing ? 'Edit chemical' : 'Add chemical',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Chemical name',
                    prefixIcon: Icon(Icons.science),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Price per unit (₹)',
                    prefixIcon: Icon(Icons.currency_rupee),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final price = double.tryParse(
                  priceController.text.trim(),
                );

                if (name.isEmpty || price == null || price < 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Enter a valid chemical name and price.',
                      ),
                    ),
                  );
                  return;
                }

                if (isEditing) {
                  await AppDatabase.instance.updateChemical(
                    id: chemical['id'] as int,
                    name: name,
                    price: price,
                  );
                } else {
                  await AppDatabase.instance.addChemical(
                    name: name,
                    price: price,
                  );
                }

                if (!mounted) return;

                Navigator.pop(dialogContext);
                await _loadChemicals();
              },
              child: Text(isEditing ? 'Save' : 'Add'),
            ),
          ],
        );
      },
    );

    nameController.dispose();
    priceController.dispose();
  }

  Future<void> _deleteChemical(
    Map<String, dynamic> chemical,
  ) async {
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

    if (shouldDelete != true) return;

    await AppDatabase.instance.deleteChemical(
      chemical['id'] as int,
    );

    await _loadChemicals();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chemical Database'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        onPressed: () => _showChemicalDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Add chemical'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(),
            )
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
              : RefreshIndicator(
                  onRefresh: _loadChemicals,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      100,
                    ),
                    itemCount: _chemicals.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final chemical = _chemicals[index];
                      final name = chemical['name'].toString();
                      final price =
                          (chemical['price'] as num).toDouble();

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
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '₹${price.toStringAsFixed(2)} per unit',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'edit') {
                                _showChemicalDialog(
                                  chemical: chemical,
                                );
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
    final plots = await AppDatabase.instance.getPlots();

    if (!mounted) return;

    setState(() {
      _plots = plots;
      _loading = false;
    });
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
                    labelText: 'Plot name or number',
                    hintText: 'Example: Plot 2',
                    prefixIcon: Icon(Icons.landscape),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cropController,
                  decoration: const InputDecoration(
                    labelText: 'Crop variety',
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

                if (title.isEmpty ||
                    plotName.isEmpty ||
                    crop.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Fill in title, plot name/number and crop variety.',
                      ),
                    ),
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

                if (!mounted) return;

                Navigator.pop(dialogContext);
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlotSpraysPage(
          plotId: plot['id'] as int,
          plotTitle: plot['title'].toString(),
          plotName: plot['plot_name'].toString(),
          cropVariety: plot['crop_variety'].toString(),
        ),
      ),
    );

    await _loadPlots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spray History'),
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
// PLOT SPRAYS PAGE
// ============================================================

class PlotSpraysPage extends StatefulWidget {
  const PlotSpraysPage({
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
  State<PlotSpraysPage> createState() => _PlotSpraysPageState();
}

class _PlotSpraysPageState extends State<PlotSpraysPage> {
  List<Map<String, dynamic>> _sprays = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSprays();
  }

  Future<void> _loadSprays() async {
    final sprays = await AppDatabase.instance.getSpraysForPlot(
      widget.plotId,
    );

    if (!mounted) return;

    setState(() {
      _sprays = sprays;
      _loading = false;
    });
  }

  Future<String> _getChemicalCombination(int sprayId) async {
    final chemicals =
        await AppDatabase.instance.getSprayChemicals(sprayId);

    return chemicals
        .map((chemical) => chemical['chemical_name'].toString())
        .join(' + ');
  }

  Future<void> _openSpray({
    Map<String, dynamic>? spray,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddSprayPage(
          plotId: widget.plotId,
          plotTitle: widget.plotTitle,
          spray: spray,
        ),
      ),
    );

    await _loadSprays();
  }

  Future<void> _deleteSpray(int sprayId) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete spray record?'),
          content: const Text(
            'This spray record and its chemical details will be deleted.',
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

    await AppDatabase.instance.deleteSpray(sprayId);

    await _loadSprays();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.plotTitle),
        actions: [
          IconButton(
            tooltip: 'Plot information',
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (_) {
                  return AlertDialog(
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
                  );
                },
              );
            },
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        onPressed: () => _openSpray(),
        icon: const Icon(Icons.add),
        label: const Text('Add spray'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : _sprays.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(30),
                    child: Text(
                      'No spray records for this plot yet.\n\nTap "Add spray" to create the first record.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : FutureBuilder<List<String>>(
                  future: Future.wait(
                    _sprays.map(
                      (spray) => _getChemicalCombination(
                        spray['id'] as int,
                      ),
                    ),
                  ),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    final combinations = snapshot.data!;

                    // The table is intentionally horizontally scrollable.
                    // Exactly six columns are shown.
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        8,
                        12,
                        8,
                        100,
                      ),
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columnSpacing: 22,
                        headingRowColor:
                            WidgetStateProperty.all(
                          const Color(0xFFE3F2FD),
                        ),
                        columns: const [
                          DataColumn(
                            label: Text(
                              'No.',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Date',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Chemical combination',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Water',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Cost',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Notes',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                        ],
                        rows: List.generate(
                          _sprays.length,
                          (index) {
                            final spray = _sprays[index];
                            final date =
                                DateTime.parse(
                              spray['spray_date'].toString(),
                            );

                            final water =
                                (spray['water'] as num).toDouble();

                            final cost =
                                (spray['total_cost'] as num).toDouble();

                            final notes =
                                spray['notes'].toString();

                            return DataRow(
                              cells: [
                                DataCell(
                                  Text('${index + 1}'),
                                ),
                                DataCell(
                                  Text(_formatDate(date)),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 240,
                                    child: Text(
                                      combinations[index],
                                    ),
                                  ),
                                ),
                                DataCell(
                                  Text(
                                    _formatNumber(water),
                                  ),
                                ),
                                DataCell(
                                  Text(
                                    '₹${cost.toStringAsFixed(2)}',
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 220,
                                    child: Text(
                                      notes.isEmpty
                                          ? '-'
                                          : notes,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    );
                  },
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
      total += chemical.dosage * chemical.price;
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
    final chemicals = await AppDatabase.instance.getChemicals();

    if (widget.spray != null) {
      final spray = widget.spray!;

      _selectedDate = DateTime.parse(
        spray['spray_date'].toString(),
      );

      _waterController.text = _formatNumber(
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

        final selected = SelectedChemical(
          id: chemicalId,
          name: row['chemical_name'].toString(),
          price: (row['price_per_unit'] as num).toDouble(),
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
          : _formatNumber(chemical.dosage),
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
                      _formatDate(_selectedDate),
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
                              '₹${(chemical['price'] as num).toDouble().toStringAsFixed(2)} per unit',
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
                                'Saved price: ₹${chemical.price.toStringAsFixed(2)} per unit',
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
                                'Chemical cost: ₹${chemical.cost.toStringAsFixed(2)}',
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
                          'Water: ${_formatNumber(_water)} L',
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
// HELPERS
// ============================================================

String _formatDate(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');

  return '$day/$month/${date.year}';
}

String _formatNumber(double value) {
  if (value == value.roundToDouble()) {
    return value.toInt().toString();
  }

  return value.toStringAsFixed(2);
}
