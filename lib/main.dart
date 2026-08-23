import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.instance.open();
  runApp(const App());
}

class Chemical {
  final int? id;
  final String name;
  final double price;

  Chemical({this.id, required this.name, required this.price});

  factory Chemical.fromMap(Map<String, Object?> row) {
    return Chemical(
      id: row['id'] as int?,
      name: row['name'] as String,
      price: (row['price'] as num).toDouble(),
    );
  }
}

class Spray {
  final int? id;
  final DateTime date;
  final double water;
  final String notes;

  Spray({this.id, required this.date,
    required this.water, required this.notes});

  factory Spray.fromMap(Map<String, Object?> row) {
    return Spray(
      id: row['id'] as int,
      date: DateTime.parse(row['date'] as String),
      water: (row['water'] as num).toDouble(),
      notes: row['notes'] as String,
    );
  }
}

class Mix {
  final int chemicalId;
  final double dosage;
  final double price;

  Mix({required this.chemicalId, required this.dosage,
    required this.price});
}

class Store {
  Store._();
  static final Store instance = Store._();
  late Database db;

  Future<void> open() async {
    final file = p.join(await getDatabasesPath(), 'agri_spray.db');
    db = await openDatabase(
      file,
      version: 1,
      onCreate: (database, version) async {
        await database.execute(
          'CREATE TABLE chemicals('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'name TEXT NOT NULL, price REAL NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE sprays('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'date TEXT NOT NULL, water REAL NOT NULL,'
          'notes TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE mixes('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'sprayId INTEGER NOT NULL, chemicalId INTEGER NOT NULL,'
          'dosage REAL NOT NULL, price REAL NOT NULL)',
        );
        await database.insert('chemicals', {
          'name': 'Tata Bahaar', 'price': 0.65,
        });
        await database.insert('chemicals', {
          'name': 'Solomon (Bayer)', 'price': 2.35,
        });
        await database.insert('chemicals', {
          'name': 'Coragen (FMC)', 'price': 14.50,
        });
      },
    );
  }

  Future<List<Chemical>> allChemicals() async {
    final rows = await db.query('chemicals', orderBy: 'name');
    return rows.map(Chemical.fromMap).toList();
  }

  Future<void> saveChemical(Chemical item) async {
    final values = {'name': item.name, 'price': item.price};
    if (item.id == null) {
      await db.insert('chemicals', values);
    } else {
      await db.update('chemicals', values,
        where: 'id=?', whereArgs: [item.id]);
    }
  }

  Future<void> deleteChemical(int id) async {
    await db.delete('chemicals', where: 'id=?', whereArgs: [id]);
  }

  Future<List<Spray>> allSprays() async {
    final rows = await db.query('sprays',
      orderBy: 'date DESC, id DESC');
    return rows.map(Spray.fromMap).toList();
  }

  Future<void> saveSpray(Spray item, List<Mix> mixes) async {
    int id;
    final values = {
      'date': item.date.toIso8601String(),
      'water': item.water,
      'notes': item.notes,
    };
    if (item.id == null) {
      id = await db.insert('sprays', values);
    } else {
      id = item.id!;
      await db.update('sprays', values,
        where: 'id=?', whereArgs: [id]);
      await db.delete('mixes', where: 'sprayId=?', whereArgs: [id]);
    }
    for (final mix in mixes) {
      await db.insert('mixes', {
        'sprayId': id,
        'chemicalId': mix.chemicalId,
        'dosage': mix.dosage,
        'price': mix.price,
      });
    }
  }

  Future<void> deleteSpray(int id) async {
    await db.delete('mixes', where: 'sprayId=?', whereArgs: [id]);
    await db.delete('sprays', where: 'id=?', whereArgs: [id]);
  }
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Agri Spray Offline',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
      ),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  int version = 0;

  void refresh() {
    setState(() => version++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agri Spray Offline')),
      body: tab == 0
          ? History(key: ValueKey('h$version'), onChange: refresh)
          : Chemicals(key: ValueKey('c$version'), onChange: refresh),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          if (tab == 0) {
            await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const Editor()));
          } else {
            await chemicalDialog(context);
          }
          refresh();
        },
        icon: const Icon(Icons.add),
        label: Text(tab == 0 ? 'New spray' : 'Add chemical'),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.history), label: 'Sprays'),
          NavigationDestination(icon: Icon(Icons.science), label: 'Chemicals'),
        ],
      ),
    );
  }
}

String dateText(DateTime date) {
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}

String money(double value) => '₹${value.toStringAsFixed(2)}';

class History extends StatelessWidget {
  final VoidCallback onChange;
  const History({super.key, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Spray>>(
      future: Store.instance.allSprays(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = snapshot.data!;
        if (list.isEmpty) {
          return const Center(
            child: Text('No records yet.\nTap New spray to begin.',
              textAlign: TextAlign.center),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final spray = list[index];
            return Card(
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.water_drop),
                ),
                title: Text(dateText(spray.date)),
                subtitle: Text(
                  '${spray.water.toStringAsFixed(1)} litres'
                  '${spray.notes.isEmpty ? '' : ' • ${spray.notes}'}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await Store.instance.deleteSpray(spray.id!);
                    onChange();
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class Chemicals extends StatelessWidget {
  final VoidCallback onChange;
  const Chemicals({super.key, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Chemical>>(
      future: Store.instance.allChemicals(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = snapshot.data!;
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final item = list[index];
            return Card(
              child: ListTile(
                leading: const Icon(Icons.science_outlined),
                title: Text(item.name),
                subtitle: Text('Price: ${money(item.price)} per unit'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () async {
                        await chemicalDialog(context, item: item);
                        onChange();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await Store.instance.deleteChemical(item.id!);
                        onChange();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

Future<void> chemicalDialog(BuildContext context,
    {Chemical? item}) async {
  final name = TextEditingController(text: item?.name ?? '');
  final price = TextEditingController(
    text: item == null ? '' : item.price.toString(),
  );
  await showDialog(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(item == null ? 'Add chemical' : 'Edit chemical'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Price per unit'),
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
              final value = double.tryParse(price.text.trim());
              if (name.text.trim().isEmpty || value == null) return;
              await Store.instance.saveChemical(Chemical(
                id: item?.id,
                name: name.text.trim(),
                price: value,
              ));
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
  name.dispose();
  price.dispose();
}

class Editor extends StatefulWidget {
  final Spray? spray;
  const Editor({super.key, this.spray});

  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  late DateTime date;
  final water = TextEditingController();
  final notes = TextEditingController();
  List<Chemical> chemicals = [];
  final dosage = <int, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    date = widget.spray?.date ?? DateTime.now();
    water.text = widget.spray?.water.toString() ?? '';
    notes.text = widget.spray?.notes ?? '';
    loadChemicals();
  }

  Future<void> loadChemicals() async {
    chemicals = await Store.instance.allChemicals();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    water.dispose();
    notes.dispose();
    for (final controller in dosage.values) {
      controller.dispose();
    }
    super.dispose();
  }

  double total() {
    double result = 0;
    for (final entry in dosage.entries) {
      final value = double.tryParse(entry.value.text) ?? 0;
      final chemical = chemicals.firstWhere((c) => c.id == entry.key);
      result += value * chemical.price;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (chemicals.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('New spray')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('New spray')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Date'),
            subtitle: Text(dateText(date)),
            trailing: IconButton(
              icon: const Icon(Icons.calendar_month),
              onPressed: () async {
                final selected = await showDatePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                  initialDate: date,
                );
                if (selected != null) {
                  setState(() => date = selected);
                }
              },
            ),
          ),
          TextField(
            controller: water,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Water quantity (litres)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          const Text('Chemicals and dosage',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          for (final chemical in chemicals)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(child: Text(chemical.name)),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: dosage.putIfAbsent(
                          chemical.id!,
                          () => TextEditingController(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Dosage',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: notes,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Estimated total: ${money(total())}',
                style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: save,
            icon: const Icon(Icons.save),
            label: const Text('Save spray'),
          ),
        ],
      ),
    );
  }

  Future<void> save() async {
    final litres = double.tryParse(water.text.trim());
    if (litres == null || litres <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter valid water quantity')),
      );
      return;
    }
    final mixes = <Mix>[];
    for (final entry in dosage.entries) {
      final amount = double.tryParse(entry.value.text) ?? 0;
      if (amount > 0) {
        final chemical = chemicals.firstWhere((c) => c.id == entry.key);
        mixes.add(Mix(
          chemicalId: chemical.id!,
          dosage: amount,
          price: chemical.price,
        ));
      }
    }
    await Store.instance.saveSpray(Spray(
      id: widget.spray?.id,
      date: date,
      water: litres,
      notes: notes.text.trim(),
    ), mixes);
    if (mounted) Navigator.pop(context);
  }
}
