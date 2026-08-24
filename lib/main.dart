import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.instance.open();
  runApp(const AgriApp());
}

class Chemical {
  final int? id;
  final String name;
  final double price;
  Chemical({this.id, required this.name, required this.price});
  factory Chemical.fromMap(Map<String, Object?> m) => Chemical(
    id: m['id'] as int?, name: m['name'] as String,
    price: (m['price'] as num).toDouble(),
  );
}

class Group {
  final int? id;
  final String title;
  final String plot;
  final String crop;
  Group({this.id, required this.title, required this.plot, required this.crop});
  factory Group.fromMap(Map<String, Object?> m) => Group(
    id: m['id'] as int?, title: m['title'] as String,
    plot: m['plot'] as String, crop: m['crop'] as String,
  );
}

class Spray {
  final int? id;
  final int groupId;
  final DateTime date;
  final double water;
  final double cost;
  final String combination;
  final String notes;
  Spray({this.id, required this.groupId, required this.date,
    required this.water, required this.cost,
    required this.combination, required this.notes});
  factory Spray.fromMap(Map<String, Object?> m) => Spray(
    id: m['id'] as int?, groupId: m['groupId'] as int,
    date: DateTime.parse(m['date'] as String),
    water: (m['water'] as num).toDouble(),
    cost: (m['cost'] as num).toDouble(),
    combination: m['combination'] as String,
    notes: m['notes'] as String,
  );
}

class Mix {
  final int chemicalId;
  final double dosage;
  final double price;
  Mix({required this.chemicalId, required this.dosage, required this.price});
}

class Store {
  Store._();
  static final instance = Store._();
  late Database db;

  Future<void> open() async {
    final file = p.join(await getDatabasesPath(), 'agri_spray.db');
    db = await openDatabase(file, version: 2, onCreate: (d, v) async {
      await d.execute('CREATE TABLE chemicals(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, price REAL NOT NULL)');
      await d.execute('CREATE TABLE groups(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plot TEXT NOT NULL, crop TEXT NOT NULL)');
      await d.execute('CREATE TABLE sprays(id INTEGER PRIMARY KEY AUTOINCREMENT, groupId INTEGER NOT NULL, date TEXT NOT NULL, water REAL NOT NULL, cost REAL NOT NULL, combination TEXT NOT NULL, notes TEXT NOT NULL)');
      await d.execute('CREATE TABLE mixes(id INTEGER PRIMARY KEY AUTOINCREMENT, sprayId INTEGER NOT NULL, chemicalId INTEGER NOT NULL, dosage REAL NOT NULL, price REAL NOT NULL)');
      await d.insert('chemicals', {'name': 'Tata Bahaar', 'price': 0.65});
      await d.insert('chemicals', {'name': 'Solomon (Bayer)', 'price': 2.35});
      await d.insert('chemicals', {'name': 'Coragen (FMC)', 'price': 14.50});
    }, onUpgrade: (d, old, v) async {
      if (old < 2) {
        await d.execute('CREATE TABLE groups(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plot TEXT NOT NULL, crop TEXT NOT NULL)');
        await d.execute('ALTER TABLE sprays ADD COLUMN groupId INTEGER NOT NULL DEFAULT 0');
        await d.execute('ALTER TABLE sprays ADD COLUMN cost REAL NOT NULL DEFAULT 0');
        await d.execute('ALTER TABLE sprays ADD COLUMN combination TEXT NOT NULL DEFAULT ""');
      }
    });
  }

  Future<List<Chemical>> chemicals() async => (await db.query('chemicals', orderBy: 'name')).map(Chemical.fromMap).toList();
  Future<void> saveChemical(Chemical c) async {
    final values = {'name': c.name, 'price': c.price};
    if (c.id == null) await db.insert('chemicals', values);
    else await db.update('chemicals', values, where: 'id=?', whereArgs: [c.id]);
  }
  Future<void> deleteChemical(int id) => db.delete('chemicals', where: 'id=?', whereArgs: [id]);

  Future<List<Group>> groups() async => (await db.query('groups', orderBy: 'title')).map(Group.fromMap).toList();
  Future<int> saveGroup(Group g) async {
    final values = {'title': g.title, 'plot': g.plot, 'crop': g.crop};
    if (g.id == null) return db.insert('groups', values);
    await db.update('groups', values, where: 'id=?', whereArgs: [g.id]);
    return g.id!;
  }
  Future<void> deleteGroup(int id) async {
    await db.delete('mixes', where: 'sprayId IN (SELECT id FROM sprays WHERE groupId=?)', whereArgs: [id]);
    await db.delete('sprays', where: 'groupId=?', whereArgs: [id]);
    await db.delete('groups', where: 'id=?', whereArgs: [id]);
  }
  Future<List<Spray>> sprays(int groupId) async => (await db.query('sprays', where: 'groupId=?', whereArgs: [groupId], orderBy: 'date DESC, id DESC')).map(Spray.fromMap).toList();
  Future<void> saveSpray(Spray s, List<Mix> mixes) async {
    final values = {'groupId': s.groupId, 'date': s.date.toIso8601String(), 'water': s.water, 'cost': s.cost, 'combination': s.combination, 'notes': s.notes};
    int id;
    if (s.id == null) id = await db.insert('sprays', values);
    else { id = s.id!; await db.update('sprays', values, where: 'id=?', whereArgs: [id]); await db.delete('mixes', where: 'sprayId=?', whereArgs: [id]); }
    for (final m in mixes) await db.insert('mixes', {'sprayId': id, 'chemicalId': m.chemicalId, 'dosage': m.dosage, 'price': m.price});
  }
  Future<void> deleteSpray(int id) async { await db.delete('mixes', where: 'sprayId=?', whereArgs: [id]); await db.delete('sprays', where: 'id=?', whereArgs: [id]); }
}

class AgriApp extends StatelessWidget {
  const AgriApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Agri Spray Offline',
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.white,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1689c7)),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xff1689c7), foregroundColor: Colors.white),
      navigationBarTheme: const NavigationBarThemeData(indicatorColor: Color(0xffb9e8ff)),
    ),
    home: const HomePage(),
  );
}

String dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
String money(double n) => '₹${n.toStringAsFixed(2)}';

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState() => _HomeState(); }
class _HomeState extends State<HomePage> {
  int tab = 0;
  int refresh = 0;
  void reload() => setState(() => refresh++);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tab == 0 ? 'Plots and crops' : 'Chemical database')),
    body: tab == 0 ? GroupList(key: ValueKey('g$refresh'), onChange: reload) : ChemicalList(key: ValueKey('c$refresh'), onChange: reload),
    floatingActionButton: FloatingActionButton.extended(
      backgroundColor: const Color(0xff123d68), foregroundColor: Colors.white,
      onPressed: () async { if (tab == 0) await groupDialog(context); else await chemicalDialog(context); reload(); },
      icon: const Icon(Icons.add), label: Text(tab == 0 ? 'Add plot / crop' : 'Add chemical'),
    ),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v), destinations: const [
      NavigationDestination(icon: Icon(Icons.agriculture), label: 'Plots'),
      NavigationDestination(icon: Icon(Icons.science), label: 'Chemicals'),
    ]),
  );
}

class GroupList extends StatelessWidget {
  final VoidCallback onChange;
  const GroupList({super.key, required this.onChange});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Group>>(
    future: Store.instance.groups(),
    builder: (context, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      if (snap.data!.isEmpty) return const Center(child: Text('No plot or crop yet.\nTap Add plot / crop.', textAlign: TextAlign.center));
      return ListView.builder(padding: const EdgeInsets.all(12), itemCount: snap.data!.length, itemBuilder: (context, i) {
        final g = snap.data![i];
        return Card(child: ListTile(
          leading: const CircleAvatar(backgroundColor: Color(0xffb9e8ff), child: Icon(Icons.eco, color: Color(0xff123d68))),
          title: Text(g.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('Plot: ${g.plot}  •  Crop: ${g.crop}'),
          trailing: PopupMenuButton<String>(onSelected: (v) async {
            if (v == 'edit') await groupDialog(context, group: g);
            if (v == 'delete') await Store.instance.deleteGroup(g.id!);
            onChange();
          }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))]),
          onTap: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupPage(group: g))); onChange(); },
        ));
      });
    },
  );
}

Future<void> groupDialog(BuildContext context, {Group? group}) async {
  final title = TextEditingController(text: group?.title ?? '');
  final plot = TextEditingController(text: group?.plot ?? '');
  final crop = TextEditingController(text: group?.crop ?? '');
  await showDialog(context: context, builder: (c) => AlertDialog(
    title: Text(group == null ? 'Add plot / crop' : 'Edit plot / crop'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: title, decoration: const InputDecoration(labelText: 'Title, for example Farm 1 - Cotton')),
      TextField(controller: plot, decoration: const InputDecoration(labelText: 'Plot name or number')),
      TextField(controller: crop, decoration: const InputDecoration(labelText: 'Crop variety')),
    ]),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () async {
      if (title.text.trim().isEmpty) return;
      await Store.instance.saveGroup(Group(id: group?.id, title: title.text.trim(), plot: plot.text.trim(), crop: crop.text.trim()));
      if (c.mounted) Navigator.pop(c);
    }, child: const Text('Save'))],
  ));
  title.dispose(); plot.dispose(); crop.dispose();
}

class GroupPage extends StatefulWidget {
  final Group group;
  const GroupPage({super.key, required this.group});
  @override State<GroupPage> createState() => _GroupState();
}
class _GroupState extends State<GroupPage> {
  int refresh = 0;
  void reload() => setState(() => refresh++);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.group.title)),
    body: SprayTable(key: ValueKey(refresh), group: widget.group, onChange: reload),
    floatingActionButton: FloatingActionButton.extended(
      backgroundColor: const Color(0xff123d68), foregroundColor: Colors.white,
      onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => SprayEditor(group: widget.group))); reload(); },
      icon: const Icon(Icons.add), label: const Text('Add spray'),
    ),
  );
}

class SprayTable extends StatelessWidget {
  final Group group;
  final VoidCallback onChange;
  const SprayTable({super.key, required this.group, required this.onChange});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Spray>>(
    future: Store.instance.sprays(group.id!),
    builder: (context, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      if (snap.data!.isEmpty) return const Center(child: Text('No sprays saved for this plot.\nTap Add spray.', textAlign: TextAlign.center));
      return SingleChildScrollView(scrollDirection: Axis.horizontal, child: SingleChildScrollView(
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(const Color(0xffb9e8ff)),
          columns: const [DataColumn(label: Text('No.')), DataColumn(label: Text('Date')), DataColumn(label: Text('Chemical combination')), DataColumn(label: Text('Water')), DataColumn(label: Text('Cost')), DataColumn(label: Text('Notes'))],
          rows: [for (var i = 0; i < snap.data!.length; i++) DataRow(cells: [
            DataCell(Text('${i + 1}')), DataCell(Text(dateText(snap.data![i].date))),
            DataCell(SizedBox(width: 220, child: Text(snap.data![i].combination))),
            DataCell(Text('${snap.data![i].water.toStringAsFixed(1)} L')),
            DataCell(Text(money(snap.data![i].cost))), DataCell(SizedBox(width: 180, child: Text(snap.data![i].notes))),
          ])],
        ),
      ));
    },
  );
}

class ChemicalList extends StatelessWidget {
  final VoidCallback onChange;
  const ChemicalList({super.key, required this.onChange});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Chemical>>(
    future: Store.instance.chemicals(),
    builder: (context, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      return ListView.builder(padding: const EdgeInsets.all(12), itemCount: snap.data!.length, itemBuilder: (context, i) {
        final c = snap.data![i];
        return Card(child: ListTile(leading: const Icon(Icons.science, color: Color(0xff123d68)), title: Text(c.name), subtitle: Text('Price: ${money(c.price)} per unit'), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.edit), onPressed: () async { await chemicalDialog(context, chemical: c); onChange(); }), IconButton(icon: const Icon(Icons.delete), onPressed: () async { await Store.instance.deleteChemical(c.id!); onChange(); })])));
      });
    },
  );
}

Future<void> chemicalDialog(BuildContext context, {Chemical? chemical}) async {
  final name = TextEditingController(text: chemical?.name ?? '');
  final price = TextEditingController(text: chemical?.price.toString() ?? '');
  await showDialog(context: context, builder: (c) => AlertDialog(title: Text(chemical == null ? 'Add chemical' : 'Edit chemical'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'Chemical name')), TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price per unit'))]), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () async { final n = double.tryParse(price.text.trim()); if (name.text.trim().isEmpty || n == null) return; await Store.instance.saveChemical(Chemical(id: chemical?.id, name: name.text.trim(), price: n)); if (c.mounted) Navigator.pop(c); }, child: const Text('Save'))]));
  name.dispose(); price.dispose();
}

class SprayEditor extends StatefulWidget {
  final Group group;
  const SprayEditor({super.key, required this.group});
  @override State<SprayEditor> createState() => _SprayEditorState();
}
class _SprayEditorState extends State<SprayEditor> {
  DateTime date = DateTime.now();
  final water = TextEditingController();
  final notes = TextEditingController();
  List<Chemical> chemicals = [];
  final chosen = <Chemical>{};
  final dosage = <int, TextEditingController>{};
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { chemicals = await Store.instance.chemicals(); if (mounted) setState(() {}); }
  @override void dispose() { water.dispose(); notes.dispose(); for (final c in dosage.values) c.dispose(); super.dispose(); }
  double get total => chosen.fold(0, (sum, c) => sum + ((double.tryParse(dosage[c.id]!.text) ?? 0) * c.price));
  Future<void> chooseChemicals() async {
    final temp = {...chosen};
    String query = '';
    await showDialog(context: context, builder: (dialog) => StatefulBuilder(builder: (dialog, setDialog) {
      final visible = chemicals.where((c) => c.name.toLowerCase().contains(query.toLowerCase())).toList();
      return AlertDialog(title: const Text('Search chemicals'), content: SizedBox(width: 360, height: 420, child: Column(children: [TextField(onChanged: (v) => setDialog(() => query = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Type chemical name')), const SizedBox(height: 8), Expanded(child: ListView(children: [for (final c in visible) CheckboxListTile(value: temp.contains(c), title: Text(c.name), subtitle: Text(money(c.price)), onChanged: (v) => setDialog(() { if (v == true) temp.add(c); else temp.remove(c); }))]))])), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')), FilledButton(onPressed: () { chosen..clear()..addAll(temp); for (final c in chosen) dosage.putIfAbsent(c.id!, () => TextEditingController()); setState(() {}); Navigator.pop(dialog); }, child: const Text('Use selected'))]);
    }));
  }
  @override
  Widget build(BuildContext context) {
    if (chemicals.isEmpty) return Scaffold(appBar: AppBar(title: const Text('Add spray')), body: const Center(child: CircularProgressIndicator()));
    return Scaffold(appBar: AppBar(title: const Text('Add spray')), body: ListView(padding: const EdgeInsets.all(16), children: [
      ListTile(contentPadding: EdgeInsets.zero, title: const Text('Date'), subtitle: Text(dateText(date)), trailing: IconButton(icon: const Icon(Icons.calendar_month), onPressed: () async { final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDate: date); if (d != null) setState(() => date = d); })),
      TextField(controller: water, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Water quantity (litres)', border: OutlineInputBorder())),
      const SizedBox(height: 16),
      OutlinedButton.icon(onPressed: chooseChemicals, icon: const Icon(Icons.search), label: Text(chosen.isEmpty ? 'Search and select chemicals' : 'Change chemicals (${chosen.length})')),
      for (final c in chosen) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [Expanded(child: Text(c.name)), SizedBox(width: 130, child: TextField(controller: dosage[c.id], onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Dosage')))])),
      const SizedBox(height: 16), TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder())),
      const SizedBox(height: 16), Card(color: const Color(0xffb9e8ff), child: Padding(padding: const EdgeInsets.all(16), child: Text('Total cost: ${money(total)}', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold, color: Color(0xff123d68))))),
      const SizedBox(height: 12), FilledButton.icon(onPressed: save, icon: const Icon(Icons.save), label: const Text('Save spray')),
    ]));
  }
  Future<void> save() async {
    final w = double.tryParse(water.text.trim());
    if (w == null || w <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter valid water quantity'))); return; }
    final mixes = <Mix>[];
    for (final c in chosen) { final d = double.tryParse(dosage[c.id]!.text) ?? 0; if (d > 0) mixes.add(Mix(chemicalId: c.id!, dosage: d, price: c.price)); }
    final combination = chosen.map((c) => c.name).join(' + ');
    await Store.instance.saveSpray(Spray(groupId: widget.group.id!, date: date, water: w, cost: total, combination: combination, notes: notes.text.trim()), mixes);
    if (mounted) Navigator.pop(context);
  }
}
