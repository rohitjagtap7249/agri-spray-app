import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DB.instance.init();
  runApp(const AgriSprayApp());
}

class Chemical {
  final int? id;
  final String name;
  final double price;
  Chemical({this.id, required this.name, required this.price});
  factory Chemical.fromMap(Map<String, Object?> m) => Chemical(
        id: m['id'] as int?,
        name: m['name'] as String,
        price: (m['price'] as num).toDouble(),
      );
}

class Mix {
  final int? id;
  final int chemicalId;
  final double dosage;
  final double unitPrice;
  Mix({this.id, required this.chemicalId, required this.dosage, required this.unitPrice});
}

class Spray {
  final int? id;
  final DateTime date;
  final double water;
  final String notes;
  Spray({this.id, required this.date, required this.water, required this.notes});
  factory Spray.fromMap(Map<String, Object?> m) => Spray(
        id: m['id'] as int,
        date: DateTime.parse(m['date'] as String),
        water: (m['water'] as num).toDouble(),
        notes: m['notes'] as String,
      );
}

class DB {
  DB._();
  static final DB instance = DB._();
  late Database db;

  Future<void> init() async {
    final path = p.join(await getDatabasesPath(), 'agri_spray.db');
    db = await openDatabase(path, version: 2, onCreate: (db, version) async {
      await db.execute('CREATE TABLE chemicals(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, price REAL NOT NULL)');
      await db.execute('CREATE TABLE sprays(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, water REAL NOT NULL, notes TEXT NOT NULL)');
      await db.execute('CREATE TABLE mixes(id INTEGER PRIMARY KEY AUTOINCREMENT, sprayId INTEGER NOT NULL, chemicalId INTEGER NOT NULL, dosage REAL NOT NULL, unitPrice REAL NOT NULL)');
      for (final c in [
        {'name': 'Tata Bahaar', 'price': 0.65},
        {'name': 'Solomon (Bayer)', 'price': 2.35},
        {'name': 'Coragen (FMC)', 'price': 14.50},
      ]) {
        await db.insert('chemicals', c);
      }
    }, onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute('ALTER TABLE mixes ADD COLUMN unitPrice REAL NOT NULL DEFAULT 0');
      }
    });
  }

  Future<List<Chemical>> chemicals() async => (await db.query('chemicals', orderBy: 'name ASC')).map(Chemical.fromMap).toList();
  Future<int> addChemical(Chemical c) => db.insert('chemicals', {'name': c.name, 'price': c.price});
  Future<void> updateChemical(Chemical c) async => db.update('chemicals', {'name': c.name, 'price': c.price}, where: 'id=?', whereArgs: [c.id]);
  Future<void> deleteChemical(int id) async => db.delete('chemicals', where: 'id=?', whereArgs: [id]);
  Future<List<Spray>> sprays() async => (await db.query('sprays', orderBy: 'date DESC, id DESC')).map(Spray.fromMap).toList();
  Future<List<Mix>> mixes(int sprayId) async => (await db.query('mixes', where: 'sprayId=?', whereArgs: [sprayId])).map((m) => Mix(id: m['id'] as int, chemicalId: m['chemicalId'] as int, dosage: (m['dosage'] as num).toDouble(), unitPrice: (m['unitPrice'] as num).toDouble())).toList();

  Future<void> saveSpray(Spray spray, List<Mix> mixList) async {
    final id = spray.id ?? await db.insert('sprays', {'date': spray.date.toIso8601String(), 'water': spray.water, 'notes': spray.notes});
    if (spray.id != null) {
      await db.update('sprays', {'date': spray.date.toIso8601String(), 'water': spray.water, 'notes': spray.notes}, where: 'id=?', whereArgs: [id]);
      await db.delete('mixes', where: 'sprayId=?', whereArgs: [id]);
    }
    for (final m in mixList) {
      await db.insert('mixes', {'sprayId': id, 'chemicalId': m.chemicalId, 'dosage': m.dosage, 'unitPrice': m.unitPrice});
    }
  }
  Future<void> deleteSpray(int id) async {
    await db.delete('mixes', where: 'sprayId=?', whereArgs: [id]);
    await db.delete('sprays', where: 'id=?', whereArgs: [id]);
  }
}

class AgriSprayApp extends StatelessWidget {
  const AgriSprayApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Agri Spray Offline',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.green),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  int refresh = 0;
  void reload() => setState(() => refresh++);
  @override
  Widget build(BuildContext context) {
    final pages = [HistoryPage(key: ValueKey('h$refresh'), onChanged: reload), ChemicalsPage(key: ValueKey('c$refresh'), onChanged: reload)];
    return Scaffold(
      appBar: AppBar(title: const Text('Agri Spray Offline'), centerTitle: true),
      body: pages[tab],
      floatingActionButton: tab == 0 ? FloatingActionButton.extended(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => const SprayEditor())); reload(); }, icon: const Icon(Icons.add), label: const Text('New spray')) : FloatingActionButton.extended(onPressed: () async { await showChemicalDialog(context); reload(); }, icon: const Icon(Icons.add), label: const Text('Add chemical')),
      bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [NavigationDestination(icon: Icon(Icons.history), label: 'Sprays'), NavigationDestination(icon: Icon(Icons.science), label: 'Chemicals')]),
    );
  }
}

String money(double v) => '₹${v.toStringAsFixed(2)}';
String dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class HistoryPage extends StatelessWidget {
  final VoidCallback onChanged;
  const HistoryPage({super.key, required this.onChanged});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Spray>>(
        future: DB.instance.sprays(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (snap.data!.isEmpty) return const Center(child: Text('No spray records yet.\nTap “New spray” to add one.', textAlign: TextAlign.center));
          return ListView.builder(padding: const EdgeInsets.all(12), itemCount: snap.data!.length, itemBuilder: (_, i) {
            final s = snap.data![i];
            return Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.water_drop)), title: Text(dateText(s.date)), subtitle: Text('${s.water.toStringAsFixed(1)} L water${s.notes.isEmpty ? '' : ' • ${s.notes}'}'), trailing: PopupMenuButton<String>(onSelected: (v) async { if (v == 'edit') { await Navigator.push(context, MaterialPageRoute(builder: (_) => SprayEditor(spray: s))); onChanged(); } else { await DB.instance.deleteSpray(s.id!); onChanged(); } }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))])));
          });
        },
      );
}

class ChemicalsPage extends StatelessWidget {
  final VoidCallback onChanged;
  const ChemicalsPage({super.key, required this.onChanged});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Chemical>>(
        future: DB.instance.chemicals(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView.builder(padding: const EdgeInsets.all(12), itemCount: snap.data!.length, itemBuilder: (_, i) { final c = snap.data![i]; return Card(child: ListTile(leading: const Icon(Icons.science_outlined), title: Text(c.name), subtitle: Text('Price: ${money(c.price)} per unit'), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.edit), onPressed: () async { await showChemicalDialog(context, chemical: c); onChanged(); }), IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await DB.instance.deleteChemical(c.id!); onChanged(); })])); });
        },
      );
}

Future<void> showChemicalDialog(BuildContext context, {Chemical? chemical}) async {
  final name = TextEditingController(text: chemical?.name ?? '');
  final price = TextEditingController(text: chemical?.price.toString() ?? '');
  await showDialog(context: context, builder: (_) => AlertDialog(title: Text(chemical == null ? 'Add chemical' : 'Edit chemical'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'Chemical name')), TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price per unit'))]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () async { final n = double.tryParse(price.text.trim()); if (name.text.trim().isEmpty || n == null) return; final c = Chemical(id: chemical?.id, name: name.text.trim(), price: n); if (chemical == null) await DB.instance.addChemical(c); else await DB.instance.updateChemical(c); if (context.mounted) Navigator.pop(context); }, child: const Text('Save'))]));
}

class SprayEditor extends StatefulWidget {
  final Spray? spray;
  const SprayEditor({super.key, this.spray});
  @override State<SprayEditor> createState() => _SprayEditorState();
}

class _SprayEditorState extends State<SprayEditor> {
  late DateTime date;
  final water = TextEditingController();
  final notes = TextEditingController();
  List<Chemical> chemicals = [];
  final selected = <int, TextEditingController>{};
  @override void initState() { super.initState(); date = widget.spray?.date ?? DateTime.now(); water.text = widget.spray?.water.toString() ?? ''; notes.text = widget.spray?.notes ?? ''; load(); }
  Future<void> load() async { chemicals = await DB.instance.chemicals(); if (mounted) setState(() {}); }
  @override void dispose() { water.dispose(); notes.dispose(); for (final c in selected.values) c.dispose(); super.dispose(); }
  double get total => selected.entries.fold(0, (sum, e) { final c = chemicals.firstWhere((x) => x.id == e.key); return sum + ((double.tryParse(e.value.text) ?? 0) * c.price); });
  @override
  Widget build(BuildContext context) {
    if (chemicals.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.spray == null ? 'New spray' : 'Edit spray')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.spray == null ? 'New spray' : 'Edit spray')),
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
                final d = await showDatePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                  initialDate: date,
                );
                if (d != null) setState(() => date = d);
              },
            ),
          ),
          TextField(
            controller: water,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Water quantity (litres)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          const Text('Chemicals and dosage', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ...chemicals.map((c) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(child: Text(c.name)),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: selected.putIfAbsent(c.id!, () => TextEditingController()),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Dosage', suffixText: ' units'),
                        ),
                      ),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 12),
          TextField(
            controller: notes,
            decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 18),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Estimated total: ${money(total)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: save, icon: const Icon(Icons.save), label: const Text('Save spray')),
        ],
      ),
    );
  }

  Future<void> save() async { final w = double.tryParse(water.text.trim()); if (w == null || w <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid water quantity'))); return; } final mixes = <Mix>[]; for (final e in selected.entries) { final d = double.tryParse(e.value.text) ?? 0; if (d > 0) { final c = chemicals.firstWhere((x) => x.id == e.key); mixes.add(Mix(chemicalId: c.id!, dosage: d, unitPrice: c.price)); } } await DB.instance.saveSpray(Spray(id: widget.spray?.id, date: date, water: w, notes: notes.text.trim()), mixes); if (mounted) Navigator.pop(context); }
}
