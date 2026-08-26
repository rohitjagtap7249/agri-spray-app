import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
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
      title: 'FarmBook',
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
  static const int _databaseVersion = 5;

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
            price REAL NOT NULL DEFAULT 0,
            unit TEXT NOT NULL DEFAULT ''
          )
        ''');

        await _createNewTables(db);
        await _createDripTables(db);
        await db.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS idx_chemicals_name_ci
          ON chemicals(name COLLATE NOCASE)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Never delete the database.
        // Never drop the chemicals table.
        //
        // The existing chemical records remain untouched.
        if (oldVersion < 2) {
          await _createNewTables(db);
        }
        if (oldVersion < 3) {
          await _migrateChemicalNames(db);
        }
        if (oldVersion < 4) {
          await _createDripTables(db);
        }
        if (oldVersion < 5) {
          await _addChemicalUnitColumn(db);
        }
      },
      onOpen: (db) async {
        // Safety net: if a previous install ever stamped the database
        // at the current version without these tables existing (e.g.
        // during development), onUpgrade will never run again. Re-run
        // the idempotent (IF NOT EXISTS) creation here on every open
        // so the app can self-heal instead of failing silently.
        await _createNewTables(db);
        await _createDripTables(db);
        await _addChemicalUnitColumn(db);
      },
    );
  }

  Future<void> _addChemicalUnitColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(chemicals)');
    final hasUnit = columns.any((column) => column['name'] == 'unit');
    if (!hasUnit) {
      await db.execute(
        "ALTER TABLE chemicals ADD COLUMN unit TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  Future<void> _migrateChemicalNames(Database db) async {
    final rows = await db.query(
      'chemicals',
      columns: ['id', 'name'],
      orderBy: 'id ASC',
    );
    final used = <String>{};
    for (final row in rows) {
      final id = row['id'] as int;
      final original = row['name'].toString().trim();
      var candidate = original;
      var key = candidate.toLowerCase();
      var suffix = 2;
      while (used.contains(key)) {
        candidate = '$original ($suffix)';
        key = candidate.toLowerCase();
        suffix++;
      }
      if (candidate != row['name'].toString()) {
        await db.update('chemicals', {'name': candidate}, where: 'id = ?', whereArgs: [id]);
      }
      used.add(key);
    }
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_chemicals_name_ci
      ON chemicals(name COLLATE NOCASE)
    ''');
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

  Future<void> _createDripTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS drip_applications (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        plot_id INTEGER NOT NULL,
        drip_date TEXT NOT NULL,
        acres REAL NOT NULL,
        total_cost REAL NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        FOREIGN KEY (plot_id) REFERENCES plots(id)
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
        cost REAL NOT NULL,
        FOREIGN KEY (drip_id) REFERENCES drip_applications(id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_drip_applications_plot_id
      ON drip_applications(plot_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_drip_chemicals_drip_id
      ON drip_chemicals(drip_id)
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

  Future<bool> chemicalNameExists(String name, {int? excludeId}) async {
    final db = await database;
    final clean = name.trim();
    final rows = await db.query(
      'chemicals',
      columns: ['id'],
      where: excludeId == null
          ? 'name COLLATE NOCASE = ?'
          : 'name COLLATE NOCASE = ? AND id != ?',
      whereArgs: excludeId == null ? [clean] : [clean, excludeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> addChemical({
    required String name,
    required double price,
    String unit = '',
  }) async {
    final db = await database;
    final clean = name.trim();
    final cleanUnit = unit.trim();
    if (await chemicalNameExists(clean)) {
      throw StateError('Chemical already exists.');
    }
    await db.insert('chemicals', {
      'name': clean,
      'price': price,
      'unit': cleanUnit,
    });
  }

  Future<void> updateChemical({
    required int id,
    required String name,
    required double price,
    String unit = '',
  }) async {
    final db = await database;
    final clean = name.trim();
    final cleanUnit = unit.trim();
    if (await chemicalNameExists(clean, excludeId: id)) {
      throw StateError('Chemical already exists.');
    }
    await db.update(
      'chemicals',
      {
        'name': clean,
        'price': price,
        'unit': cleanUnit,
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
    final rawSprays = await db.query(
      'sprays',
      where: 'plot_id = ?',
      whereArgs: [plotId],
      orderBy: 'spray_date DESC, id DESC',
    );

    final sprays = <Map<String, dynamic>>[];

    for (final row in rawSprays) {
      // db.query() rows can be read-only in newer sqflite versions,
      // so copy into a mutable map before adding computed fields.
      final spray = Map<String, dynamic>.from(row);

      final sprayId = spray['id'] as int;
      final water = (spray['water'] as num).toDouble();
      final chemicals = await db.query(
        'spray_chemicals',
        where: 'spray_id = ?',
        whereArgs: [sprayId],
      );
      spray['total_cost'] = chemicals.fold<double>(
        0,
        (sum, c) => sum + water * (c['dosage'] as num).toDouble() *
            (c['price_per_unit'] as num).toDouble(),
      );

      sprays.add(spray);
    }

    return sprays;
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
          'cost': water * dosage * price,
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
          'cost': water * chemical.dosage * chemical.price,
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

  // ------------------------------------------------------------
  // DRIP APPLICATIONS
  // ------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getDripApplicationsForPlot(int plotId) async {
    final db = await database;
    final rows = await db.query(
      'drip_applications',
      where: 'plot_id = ?',
      whereArgs: [plotId],
      orderBy: 'drip_date DESC, id DESC',
    );

    final applications = <Map<String, dynamic>>[];
    for (final row in rows) {
      final item = Map<String, dynamic>.from(row);
      final chemicals = await db.query(
        'drip_chemicals',
        where: 'drip_id = ?',
        whereArgs: [item['id']],
      );
      item['total_cost'] = chemicals.fold<double>(
        0,
        (sum, c) => sum + (c['cost'] as num).toDouble(),
      );
      applications.add(item);
    }
    return applications;
  }

  Future<List<Map<String, dynamic>>> getDripChemicals(int dripId) async {
    final db = await database;
    return db.query(
      'drip_chemicals',
      where: 'drip_id = ?',
      whereArgs: [dripId],
      orderBy: 'id ASC',
    );
  }

  Future<int> addDripApplication({
    required int plotId,
    required DateTime date,
    required double acres,
    required double totalCost,
    required String notes,
    required List<SelectedDripChemical> chemicals,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final dripId = await txn.insert('drip_applications', {
        'plot_id': plotId,
        'drip_date': date.toIso8601String(),
        'acres': acres,
        'total_cost': totalCost,
        'notes': notes.trim(),
        'created_at': DateTime.now().toIso8601String(),
      });

      for (final chemical in chemicals) {
        final multiplier = chemical.dosageUnit == 'L/acre' ? 1000.0 : 1000.0;
        final cost = acres * chemical.dosage * multiplier * chemical.price;
        await txn.insert('drip_chemicals', {
          'drip_id': dripId,
          'chemical_id': chemical.id,
          'chemical_name': chemical.name,
          'dosage': chemical.dosage,
          'dosage_unit': chemical.dosageUnit,
          'price_per_unit': chemical.price,
          'cost': cost,
        });
      }
      return dripId;
    });
  }

  Future<void> updateDripApplication({
    required int dripId,
    required int plotId,
    required DateTime date,
    required double acres,
    required double totalCost,
    required String notes,
    required List<SelectedDripChemical> chemicals,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'drip_applications',
        {
          'plot_id': plotId,
          'drip_date': date.toIso8601String(),
          'acres': acres,
          'total_cost': totalCost,
          'notes': notes.trim(),
        },
        where: 'id = ?',
        whereArgs: [dripId],
      );

      await txn.delete(
        'drip_chemicals',
        where: 'drip_id = ?',
        whereArgs: [dripId],
      );

      for (final chemical in chemicals) {
        final multiplier = chemical.dosageUnit == 'L/acre' ? 1000.0 : 1000.0;
        final cost = acres * chemical.dosage * multiplier * chemical.price;
        await txn.insert('drip_chemicals', {
          'drip_id': dripId,
          'chemical_id': chemical.id,
          'chemical_name': chemical.name,
          'dosage': chemical.dosage,
          'dosage_unit': chemical.dosageUnit,
          'price_per_unit': chemical.price,
          'cost': cost,
        });
      }
    });
  }

  Future<void> deleteDripApplication(int dripId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'drip_chemicals',
        where: 'drip_id = ?',
        whereArgs: [dripId],
      );
      await txn.delete(
        'drip_applications',
        where: 'id = ?',
        whereArgs: [dripId],
      );
    });
  }


  // ------------------------------------------------------------
  // HISTORY BACKUP / RESTORE
  // ------------------------------------------------------------

  Future<Map<String, dynamic>> exportHistory() async {
    final db = await database;

    final plots = await db.query('plots', orderBy: 'id ASC');
    final sprays = await db.query('sprays', orderBy: 'id ASC');
    final sprayChemicals = await db.query('spray_chemicals', orderBy: 'id ASC');
    final drips = await db.query('drip_applications', orderBy: 'id ASC');
    final dripChemicals = await db.query('drip_chemicals', orderBy: 'id ASC');

    return {
      'format': 'FarmBook spray history backup',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'plots': plots.map(Map<String, dynamic>.from).toList(),
      'sprays': sprays.map(Map<String, dynamic>.from).toList(),
      'spray_chemicals':
          sprayChemicals.map(Map<String, dynamic>.from).toList(),
      'drip_applications': drips.map(Map<String, dynamic>.from).toList(),
      'drip_chemicals':
          dripChemicals.map(Map<String, dynamic>.from).toList(),
    };
  }

  Future<Map<String, int>> restoreHistory(
    Map<String, dynamic> payload,
  ) async {
    final db = await database;

    final rawPlots = payload['plots'];
    final rawSprays = payload['sprays'];
    final rawSprayChemicals = payload['spray_chemicals'];
    final rawDrips = payload['drip_applications'];
    final rawDripChemicals = payload['drip_chemicals'];

    if (rawPlots is! List ||
        rawSprays is! List ||
        rawSprayChemicals is! List ||
        rawDrips is! List ||
        rawDripChemicals is! List) {
      throw const FormatException(
        'This is not a valid FarmBook history backup.',
      );
    }

    int plotsAdded = 0;
    int spraysAdded = 0;
    int dripsAdded = 0;
    int skipped = 0;

    await db.transaction((txn) async {
      final plotIdMap = <int, int>{};

      // Match plots by their user-visible information. If the plot already
      // exists, reuse it rather than creating a duplicate plot.
      for (final item in rawPlots) {
        if (item is! Map) {
          skipped++;
          continue;
        }

        final oldId = _backupInt(item['id']);
        final title = item['title']?.toString().trim() ?? '';
        final plotName = item['plot_name']?.toString().trim() ?? '';
        final crop = item['crop_variety']?.toString().trim() ?? '';
        final createdAt = item['created_at']?.toString() ??
            DateTime.now().toIso8601String();

        if (oldId == null || title.isEmpty) {
          skipped++;
          continue;
        }

        final existing = await txn.query(
          'plots',
          columns: ['id'],
          where: 'title = ? AND plot_name = ? AND crop_variety = ?',
          whereArgs: [title, plotName, crop],
          limit: 1,
        );

        if (existing.isNotEmpty) {
          plotIdMap[oldId] = existing.first['id'] as int;
        } else {
          final newId = await txn.insert('plots', {
            'title': title,
            'plot_name': plotName,
            'crop_variety': crop,
            'created_at': createdAt,
          });
          plotIdMap[oldId] = newId;
          plotsAdded++;
        }
      }

      final sprayChemicalGroups = <int, List<Map<String, dynamic>>>{};
      for (final item in rawSprayChemicals) {
        if (item is! Map) continue;
        final sprayId = _backupInt(item['spray_id']);
        if (sprayId == null) continue;
        sprayChemicalGroups.putIfAbsent(sprayId, () => []).add(
              Map<String, dynamic>.from(item),
            );
      }

      final dripChemicalGroups = <int, List<Map<String, dynamic>>>{};
      for (final item in rawDripChemicals) {
        if (item is! Map) continue;
        final dripId = _backupInt(item['drip_id']);
        if (dripId == null) continue;
        dripChemicalGroups.putIfAbsent(dripId, () => []).add(
              Map<String, dynamic>.from(item),
            );
      }

      // Restore sprays. Exact duplicates are skipped, so importing the same
      // backup twice will not create a second copy of the same history.
      for (final item in rawSprays) {
        if (item is! Map) {
          skipped++;
          continue;
        }

        final oldId = _backupInt(item['id']);
        final oldPlotId = _backupInt(item['plot_id']);
        final plotId = oldPlotId == null ? null : plotIdMap[oldPlotId];
        final date = item['spray_date']?.toString() ?? '';
        final water = _backupDouble(item['water']);
        final totalCost = _backupDouble(item['total_cost']);
        final notes = item['notes']?.toString() ?? '';
        final createdAt = item['created_at']?.toString() ??
            DateTime.now().toIso8601String();

        if (oldId == null || plotId == null || date.isEmpty || water == null ||
            totalCost == null) {
          skipped++;
          continue;
        }

        final chemicals = sprayChemicalGroups[oldId] ?? [];
        final duplicate = await _sprayAlreadyExists(
          txn,
          plotId: plotId,
          date: date,
          water: water,
          notes: notes,
          chemicals: chemicals,
        );

        if (duplicate) {
          skipped++;
          continue;
        }

        final newSprayId = await txn.insert('sprays', {
          'plot_id': plotId,
          'spray_date': date,
          'water': water,
          'total_cost': totalCost,
          'notes': notes,
          'created_at': createdAt,
        });

        for (final chemical in chemicals) {
          final name = chemical['chemical_name']?.toString() ?? '';
          final dosage = _backupDouble(chemical['dosage']);
          final price = _backupDouble(chemical['price_per_unit']);
          final cost = _backupDouble(chemical['cost']);
          if (name.isEmpty || dosage == null || price == null || cost == null) {
            continue;
          }

          await txn.insert('spray_chemicals', {
            'spray_id': newSprayId,
            'chemical_id': _backupInt(chemical['chemical_id']),
            'chemical_name': name,
            'dosage': dosage,
            'price_per_unit': price,
            'cost': cost,
          });
        }
        spraysAdded++;
      }

      // Restore drip applications too, because drip records are part of the
      // same plot history in FarmBook.
      for (final item in rawDrips) {
        if (item is! Map) {
          skipped++;
          continue;
        }

        final oldId = _backupInt(item['id']);
        final oldPlotId = _backupInt(item['plot_id']);
        final plotId = oldPlotId == null ? null : plotIdMap[oldPlotId];
        final date = item['drip_date']?.toString() ?? '';
        final acres = _backupDouble(item['acres']);
        final totalCost = _backupDouble(item['total_cost']);
        final notes = item['notes']?.toString() ?? '';
        final createdAt = item['created_at']?.toString() ??
            DateTime.now().toIso8601String();

        if (oldId == null || plotId == null || date.isEmpty || acres == null ||
            totalCost == null) {
          skipped++;
          continue;
        }

        final chemicals = dripChemicalGroups[oldId] ?? [];
        final duplicate = await _dripAlreadyExists(
          txn,
          plotId: plotId,
          date: date,
          acres: acres,
          notes: notes,
          chemicals: chemicals,
        );

        if (duplicate) {
          skipped++;
          continue;
        }

        final newDripId = await txn.insert('drip_applications', {
          'plot_id': plotId,
          'drip_date': date,
          'acres': acres,
          'total_cost': totalCost,
          'notes': notes,
          'created_at': createdAt,
        });

        for (final chemical in chemicals) {
          final name = chemical['chemical_name']?.toString() ?? '';
          final dosage = _backupDouble(chemical['dosage']);
          final unit = chemical['dosage_unit']?.toString() ?? '';
          final price = _backupDouble(chemical['price_per_unit']);
          final cost = _backupDouble(chemical['cost']);
          if (name.isEmpty || dosage == null || unit.isEmpty || price == null ||
              cost == null) {
            continue;
          }

          await txn.insert('drip_chemicals', {
            'drip_id': newDripId,
            'chemical_id': _backupInt(chemical['chemical_id']),
            'chemical_name': name,
            'dosage': dosage,
            'dosage_unit': unit,
            'price_per_unit': price,
            'cost': cost,
          });
        }
        dripsAdded++;
      }
    });

    return {
      'plots_added': plotsAdded,
      'sprays_added': spraysAdded,
      'drips_added': dripsAdded,
      'skipped': skipped,
    };
  }

  Future<bool> _sprayAlreadyExists(
    DatabaseExecutor txn, {
    required int plotId,
    required String date,
    required double water,
    required String notes,
    required List<Map<String, dynamic>> chemicals,
  }) async {
    final rows = await txn.query(
      'sprays',
      columns: ['id'],
      where: 'plot_id = ? AND spray_date = ? AND water = ? AND notes = ?',
      whereArgs: [plotId, date, water, notes],
    );

    for (final row in rows) {
      final existing = await txn.query(
        'spray_chemicals',
        where: 'spray_id = ?',
        whereArgs: [row['id']],
        orderBy: 'id ASC',
      );
      if (_chemicalRowsMatch(existing, chemicals, isDrip: false)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _dripAlreadyExists(
    DatabaseExecutor txn, {
    required int plotId,
    required String date,
    required double acres,
    required String notes,
    required List<Map<String, dynamic>> chemicals,
  }) async {
    final rows = await txn.query(
      'drip_applications',
      columns: ['id'],
      where: 'plot_id = ? AND drip_date = ? AND acres = ? AND notes = ?',
      whereArgs: [plotId, date, acres, notes],
    );

    for (final row in rows) {
      final existing = await txn.query(
        'drip_chemicals',
        where: 'drip_id = ?',
        whereArgs: [row['id']],
        orderBy: 'id ASC',
      );
      if (_chemicalRowsMatch(existing, chemicals, isDrip: true)) {
        return true;
      }
    }
    return false;
  }

  bool _chemicalRowsMatch(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> backup, {
    required bool isDrip,
  }) {
    if (existing.length != backup.length) return false;

    for (var i = 0; i < existing.length; i++) {
      final a = existing[i];
      final b = backup[i];
      if (a['chemical_name'].toString() != b['chemical_name'].toString()) {
        return false;
      }
      if (!_sameDouble(a['dosage'], b['dosage'])) return false;
      if (!_sameDouble(a['price_per_unit'], b['price_per_unit'])) return false;
      if (!_sameDouble(a['cost'], b['cost'])) return false;
      if (isDrip &&
          a['dosage_unit'].toString() != b['dosage_unit'].toString()) {
        return false;
      }
    }
    return true;
  }

  bool _sameDouble(dynamic a, dynamic b) {
    final da = _backupDouble(a);
    final db = _backupDouble(b);
    if (da == null || db == null) return false;
    return (da - db).abs() < 0.000001;
  }

  int? _backupInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _backupDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
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
    this.unit = '',
    this.dosage = 0,
  });

  final int id;
  final String name;
  final double price;
  final String unit;
  double dosage;

  double get cost => dosage * price;
}


class SelectedDripChemical {
  SelectedDripChemical({
    required this.id,
    required this.name,
    required this.price,
    this.dosage = 0,
    this.dosageUnit = 'L/acre',
  });

  final int id;
  final String name;
  final double price;
  double dosage;
  String dosageUnit;
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
  List<Map<String, dynamic>> _chemicals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChemicals();
  }

  Future<void> _loadChemicals() async {
    try {
      final chemicals = await AppDatabase.instance.getChemicals();
      if (!mounted) return;
      setState(() {
        _chemicals = chemicals;
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
          : _formatNumber((chemical['price'] as num).toDouble()),
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
                  priceController.text = _formatNumber(calculated);
                  packageSummary =
                      '${_formatNumber(size)} $selectedUnit for ₹${_formatNumber(packagePrice)} → '
                      '₹${_formatNumber(calculated)} per $selectedUnit';
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
                              labelText: 'Unit',
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
                        'Unit and price are optional. Choose the unit you normally use for dosage.',
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

                    if (name.isEmpty || price == null || price < 0) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text('Enter a valid chemical name and price.'),
                        ),
                      );
                      return;
                    }

                    final duplicate =
                        await AppDatabase.instance.chemicalNameExists(
                      name,
                      excludeId: isEditing ? chemical['id'] as int : null,
                    );
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
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Chemical already exists. Use a different name.',
                          ),
                        ),
                      );
                      return;
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
              : RefreshIndicator(
                  onRefresh: _loadChemicals,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                    itemCount: _chemicals.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final chemical = _chemicals[index];
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
                                    : 'Price not set'),
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

  Future<void> _exportHistory() async {
    try {
      final payload = await AppDatabase.instance.exportHistory();
      final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
      final fileName =
          'FarmBook_history_${DateTime.now().millisecondsSinceEpoch}.json';

      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Backup Spray History',
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null) return;

      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(path)],
        text: 'FarmBook spray history backup',
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

      if (decoded['format']?.toString() != 'FarmBook spray history backup' &&
          decoded['format']?.toString() != 'SprayBook spray history backup') {
        throw const FormatException(
          'This file is not a FarmBook spray history backup.',
        );
      }

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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restore complete: $plotsAdded plots, $spraysAdded sprays, '
            '$dripsAdded drips added${skipped == 0 ? '' : ', $skipped skipped'}.',
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
        actions: [
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
                  title: Text('Spray History Backup'),
                ),
              ),
              PopupMenuItem(
                value: 'restore',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.download),
                  title: Text('Spray History Restore'),
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
// PLOT HISTORY / SPRAY + DRIP PAGE
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
  List<Map<String, dynamic>> _records = [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
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
      final sprays = await AppDatabase.instance.getSpraysForPlot(widget.plotId);
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
              .map(
                (c) =>
                    '${c['chemical_name']} (${_formatNumber((c['dosage'] as num).toDouble())} ${c['dosage_unit']})',
              )
              .join(' + '),
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

  @override
  Widget build(BuildContext context) {
    final total = _records.fold<double>(
      0,
      (sum, record) => sum + (record['total_cost'] as num).toDouble(),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.plotTitle),
        actions: [
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton.extended(
              heroTag: 'add_spray_${widget.plotId}',
              backgroundColor: const Color(0xFF0D47A1),
              foregroundColor: Colors.white,
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AddSprayPage(
                      plotId: widget.plotId,
                      plotTitle: widget.plotTitle,
                    ),
                  ),
                );
                await _loadRecords();
              },
              icon: const Icon(Icons.water_drop),
              label: const Text('Add spray'),
            ),
            const SizedBox(width: 10),
            FloatingActionButton.extended(
              heroTag: 'add_drip_${widget.plotId}',
              backgroundColor: Colors.teal.shade700,
              foregroundColor: Colors.white,
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AddDripPage(
                      plotId: widget.plotId,
                      plotTitle: widget.plotTitle,
                    ),
                  ),
                );
                await _loadRecords();
              },
              icon: const Icon(Icons.opacity),
              label: const Text('Add drip application'),
            ),
          ],
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
              : _records.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(30),
                        child: Text(
                          'No spray or drip records for this plot yet.\n\nUse "Add spray" or "Add drip application" to create a record.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 120),
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'Tap a record row to edit it. Spray and drip records are both included in the total.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                        SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columnSpacing: 22,
                            headingRowColor: MaterialStateProperty.all(
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
                                  'Type',
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
                                  'Chemical / dosage',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0D47A1),
                                  ),
                                ),
                              ),
                              DataColumn(
                                label: Text(
                                  'Water / Acres',
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
                              DataColumn(
                                label: Text(
                                  'Action',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0D47A1),
                                  ),
                                ),
                              ),
                            ],
                            rows: List.generate(_records.length, (index) {
                              final record = _records[index];
                              final date =
                                  DateTime.parse(record['date'].toString());
                              final isSpray = record['record_type'] == 'Spray';
                              final quantity =
                                  (record['quantity'] as num).toDouble();
                              final cost =
                                  (record['total_cost'] as num).toDouble();

                              return DataRow(
                                onSelectChanged: (_) => _openRecord(record),
                                cells: [
                                  DataCell(Text('${index + 1}')),
                                  DataCell(
                                    Chip(
                                      label: Text(
                                        isSpray ? 'SPRAY' : 'DRIP',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      avatar: Icon(
                                        isSpray
                                            ? Icons.water_drop
                                            : Icons.opacity,
                                        size: 16,
                                      ),
                                    ),
                                  ),
                                  DataCell(Text(_formatDate(date))),
                                  DataCell(
                                    SizedBox(
                                      width: 260,
                                      child: Text(record['chemicals'].toString()),
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      isSpray
                                          ? '${_formatNumber(quantity)} L'
                                          : '${_formatNumber(quantity)} acres',
                                    ),
                                  ),
                                  DataCell(
                                    Text('₹${cost.toStringAsFixed(2)}'),
                                  ),
                                  DataCell(
                                    SizedBox(
                                      width: 220,
                                      child: Text(
                                        record['notes'].toString().isEmpty
                                            ? '-'
                                            : record['notes'].toString(),
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    IconButton(
                                      tooltip: 'Delete',
                                      onPressed: () => _deleteRecord(record),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Card(
                            color: const Color(0xFFE3F2FD),
                            elevation: 0,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Total cost: ₹${total.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0D47A1),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
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
    // L/acre is converted to ml/acre and kg/acre to gram/acre.
    // Both conversions are x1000 because the chemical price is stored
    // per ml or per gram respectively.
    return _acres * chemical.dosage * 1000.0 * chemical.price;
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
            _formatNumber((drip['acres'] as num).toDouble());
        _notesController.text = drip['notes'].toString();

        final rows =
            await AppDatabase.instance.getDripChemicals(drip['id'] as int);

        for (final row in rows) {
          final chemicalId = row['chemical_id'] as int?;
          if (chemicalId == null) continue;

          final selected = SelectedDripChemical(
            id: chemicalId,
            name: row['chemical_name'].toString(),
            price: (row['price_per_unit'] as num).toDouble(),
            dosage: (row['dosage'] as num).toDouble(),
            dosageUnit: row['dosage_unit'].toString(),
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
      text: chemical.dosage == 0 ? '' : _formatNumber(chemical.dosage),
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

    final selected = SelectedDripChemical(
      id: id,
      name: row['name'].toString(),
      price: (row['price'] as num).toDouble(),
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
                    child: Text(_formatDate(_selectedDate)),
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
                                  child: DropdownButtonFormField<String>(
                                    value: chemical.dosageUnit,
                                    decoration: const InputDecoration(
                                      labelText: 'Dosage unit',
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'L/acre',
                                        child: Text('L/acre'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'kg/acre',
                                        child: Text('kg/acre'),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setState(
                                        () => chemical.dosageUnit = value,
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Cost: ${_formatNumber(_acres)} acres × '
                              '${_formatNumber(chemical.dosage)} ${chemical.dosageUnit} × '
                              '1000 × ₹${chemical.price.toStringAsFixed(2)} = '
                              '₹${_chemicalCost(chemical).toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              chemical.dosageUnit == 'L/acre'
                                  ? 'L/acre is converted to ml/acre × 1000.'
                                  : 'kg/acre is converted to gram/acre × 1000.',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
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
                          'Acreage: ${_formatNumber(_acres)} acres',
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
                                'Cost: ${_formatNumber(_water)} × ${_formatNumber(chemical.dosage)} × ₹${chemical.price.toStringAsFixed(2)} = ₹${(_water * chemical.dosage * chemical.price).toStringAsFixed(2)}',
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
