import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DB.instance.init();
  runApp(const AgriSprayApp());
}

// =========================
// MODELS
// =========================

class Chemical {
  final int? id;
  final String name;
  final double price;

  Chemical({
    this.id,
    required this.name,
    required this.price,
  });

  factory Chemical.fromMap(Map<String, Object?> m) {
    return Chemical(
      id: m['id'] as int?,
      name: m['name'] as String,
      price: (m['price'] as num).toDouble(),
    );
  }
}

class Mix {
  final int? id;
  final int chemicalId;
  final double dosage;
  final double unitPrice;

  Mix({
    this.id,
    required this.chemicalId,
    required this.dosage,
    required this.unitPrice,
  });
}

class Spray {
  final int? id;
  final DateTime date;
  final double water;
  final String notes;

  Spray({
    this.id,
    required this.date,
    required this.water,
    required this.notes,
  });
}

// =========================
// DATABASE
// =========================

class DB {
  DB._();

  static final DB instance = DB._();

  late Database db;

  Future<void> init() async {
    final databasePath = p.join(
      await getDatabasesPath(),
      'agri_spray.db',
    );

    db = await openDatabase(
      databasePath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE chemicals(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            price REAL NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE sprays(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            water REAL NOT NULL,
            notes TEXT NOT NULL
          )
        ''');

        // unitPrice is stored here so historical records
        // keep the price used on the spray date.
        await db.execute('''
          CREATE TABLE mixes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sprayId INTEGER NOT NULL,
            chemicalId INTEGER NOT NULL,
            dosage REAL NOT NULL,
            unitPrice REAL NOT NULL
          )
        ''');

        await db.insert('chemicals', {
          'name': 'Tata Bahaar',
          'price': 0.65,
        });

        await db.insert('chemicals', {
          'name': 'Solomon (Bayer)',
          'price': 2.35,
        });

        await db.insert('chemicals', {
          'name': 'Coragen (FMC)',
          'price': 14.50,
        });
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE mixes ADD COLUMN unitPrice REAL NOT NULL DEFAULT 0',
          );
        }
      },
    );
  }

  Future<List<Chemical>> chemicals() async {
    final rows = await db.query(
      'chemicals',
      orderBy: 'name ASC',
    );

    return rows.map(Chemical.fromMap).toList();
  }

  Future<int> addChemical(Chemical chemical) async {
    return db.insert('chemicals', {
      'name': chemical.name,
      'price': chemical.price,
    });
  }

  Future<void> updateChemical(Chemical chemical) async {
    await db.update(
      'chemicals',
      {
        'name': chemical.name,
        'price': chemical.price,
      },
      where: 'id=?',
      whereArgs: [chemical.id],
    );
  }

  Future<List<Spray>> sprays() async {
    final rows = await db.query(
      'sprays',
      orderBy: 'date DESC, id DESC',
    );

    return rows.map((m) {
      return Spray(
        id: m['id'] as int,
        date: DateTime.parse(m['date'] as String),
        water: (m['water'] as num).toDouble(),
        notes: m['notes'] as String,
      );
    }).toList();
  }

  Future<List<Mix>> mixes(int sprayId) async {
    final rows = await db.query(
      'mixes',
      where: 'sprayId=?',
      whereArgs: [sprayId],
    );

    return rows.map((m) {
      return Mix(
        id: m['id'] as int,
        chemicalId: m['chemicalId'] as int,
        dosage: (m['dosage'] as num).toDouble(),
        unitPrice: (m['unitPrice'] as num).toDouble(),
      );
    }).toList();
  }

  Future<void> saveSpray(
    Spray spray,
    List<Mix> mixes,
  ) async {
    int sprayId;

    if (spray.id == null) {
      sprayId = await db.insert('sprays', {
        'date': spray.date.toIso8601String(),
        'water': spray.water,
        'notes': spray.notes,
      });
    } else {
      sprayId = spray.id!;

      await db.update(
        'sprays',
        {
          'date': spray.date.toIso8601String(),
          'water': spray.water,
          'notes': spray.notes,
        },
        where: 'id=?',
        whereArgs: [sprayId],
      );

      await db.delete(
        'mixes',
        where: 'sprayId=?',
        whereArgs: [sprayId],
      );
    }

    for (final mix in mixes) {
      await db.insert('mixes', {
        'sprayId': sprayId,
        'chemicalId': mix.chemicalId,
        'dosage': mix.dosage,
        'unitPrice': mix.unitPrice,
      });
    }
  }

  Future<void> deleteSpray(int sprayId) async {
    await db.delete(
      'mixes',
      where: 'sprayId=?',
      whereArgs: [sprayId],
    );

    await db.delete(
      'sprays',
      where: 'id=?',
      whereArgs: [sprayId],
    );
  }
}

// =========================
// APP
// =========================

class AgriSprayApp extends StatelessWidget {
  const AgriSprayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Agri Spray',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Agri Spray Offline'),
        ),
        body: const Center(
          child: Text('Agri Spray app'),
        ),
      ),
    );
  }
}

