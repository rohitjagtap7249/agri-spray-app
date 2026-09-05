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
  static const int _databaseVersion = 6;

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
        await _createFinanceTables(db);
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
        if (oldVersion < 6) {
          await _createFinanceTables(db);
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
        await _createFinanceTables(db);
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

  Future<void> _createFinanceTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS labour_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT, plot_id INTEGER NOT NULL,
        labour_date TEXT NOT NULL, work_type TEXT NOT NULL,
        worker_count REAL NOT NULL DEFAULT 0, rate REAL NOT NULL DEFAULT 0,
        total_cost REAL NOT NULL, notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS other_expenses (
        id INTEGER PRIMARY KEY AUTOINCREMENT, plot_id INTEGER NOT NULL,
        expense_date TEXT NOT NULL, category TEXT NOT NULL, description TEXT NOT NULL,
        amount REAL NOT NULL, notes TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS earnings (
        id INTEGER PRIMARY KEY AUTOINCREMENT, plot_id INTEGER NOT NULL,
        earning_date TEXT NOT NULL, description TEXT NOT NULL,
        quantity REAL NOT NULL DEFAULT 0, unit TEXT NOT NULL DEFAULT '',
        price REAL NOT NULL DEFAULT 0, amount REAL NOT NULL,
        notes TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_labour_plot_id ON labour_records(plot_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_other_plot_id ON other_expenses(plot_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_earnings_plot_id ON earnings(plot_id)');
  }

  Future<bool> directLastPageEnabled() async {
    final rows=await (await database).query('app_settings',where:'key=?',whereArgs:['direct_last_page'],limit:1);
    return rows.isNotEmpty && rows.first['value']=='1';
  }
  Future<void> setDirectLastPageEnabled(bool enabled) async {
    await (await database).insert('app_settings',{'key':'direct_last_page','value':enabled?'1':'0'},conflictAlgorithm:ConflictAlgorithm.replace);
  }
  Future<String?> getLastPage(int plotId) async {
    final rows=await (await database).query('app_settings',where:'key=?',whereArgs:['last_page_$plotId'],limit:1);
    return rows.isEmpty?null:rows.first['value']?.toString();
  }
  Future<void> setLastPage(int plotId,String page) async {
    await (await database).insert('app_settings',{'key':'last_page_$plotId','value':page},conflictAlgorithm:ConflictAlgorithm.replace);
  }
  Future<List<Map<String,dynamic>>> getLabour(int plotId) async => (await database).query('labour_records',where:'plot_id=?',whereArgs:[plotId],orderBy:'labour_date DESC,id DESC');
  Future<int> addLabour({required int plotId,required DateTime date,required String workType,required double workerCount,required double rate,required double totalCost,required String notes}) async => (await database).insert('labour_records',{'plot_id':plotId,'labour_date':date.toIso8601String(),'work_type':workType.trim(),'worker_count':workerCount,'rate':rate,'total_cost':totalCost,'notes':notes.trim(),'created_at':DateTime.now().toIso8601String()});
  Future<void> updateLabour({required int id,required DateTime date,required String workType,required double workerCount,required double rate,required double totalCost,required String notes}) async => (await database).update('labour_records',{'labour_date':date.toIso8601String(),'work_type':workType.trim(),'worker_count':workerCount,'rate':rate,'total_cost':totalCost,'notes':notes.trim()},where:'id=?',whereArgs:[id]);
  Future<void> deleteLabour(int id) async => (await database).delete('labour_records',where:'id=?',whereArgs:[id]);
  Future<List<Map<String,dynamic>>> getOtherExpenses(int plotId) async => (await database).query('other_expenses',where:'plot_id=?',whereArgs:[plotId],orderBy:'expense_date DESC,id DESC');
  Future<int> addOtherExpense({required int plotId,required DateTime date,required String category,required String description,required double amount,required String notes}) async => (await database).insert('other_expenses',{'plot_id':plotId,'expense_date':date.toIso8601String(),'category':category.trim(),'description':description.trim(),'amount':amount,'notes':notes.trim(),'created_at':DateTime.now().toIso8601String()});
  Future<void> updateOtherExpense({required int id,required DateTime date,required String category,required String description,required double amount,required String notes}) async => (await database).update('other_expenses',{'expense_date':date.toIso8601String(),'category':category.trim(),'description':description.trim(),'amount':amount,'notes':notes.trim()},where:'id=?',whereArgs:[id]);
  Future<void> deleteOtherExpense(int id) async => (await database).delete('other_expenses',where:'id=?',whereArgs:[id]);
  Future<List<Map<String,dynamic>>> getEarnings(int plotId) async => (await database).query('earnings',where:'plot_id=?',whereArgs:[plotId],orderBy:'earning_date DESC,id DESC');
  Future<int> addEarning({required int plotId,required DateTime date,required String description,required double quantity,required String unit,required double price,required double amount,required String notes}) async => (await database).insert('earnings',{'plot_id':plotId,'earning_date':date.toIso8601String(),'description':description.trim(),'quantity':quantity,'unit':unit.trim(),'price':price,'amount':amount,'notes':notes.trim(),'created_at':DateTime.now().toIso8601String()});
  Future<void> updateEarning({required int id,required DateTime date,required String description,required double quantity,required String unit,required double price,required double amount,required String notes}) async => (await database).update('earnings',{'earning_date':date.toIso8601String(),'description':description.trim(),'quantity':quantity,'unit':unit.trim(),'price':price,'amount':amount,'notes':notes.trim()},where:'id=?',whereArgs:[id]);
  Future<void> deleteEarning(int id) async => (await database).delete('earnings',where:'id=?',whereArgs:[id]);
  Future<Map<String,double>> plotTotals(int plotId) async {
    final sprays=await getSpraysForPlot(plotId), drips=await getDripApplicationsForPlot(plotId);
    final db=await database; final l=await db.query('labour_records',where:'plot_id=?',whereArgs:[plotId]); final o=await db.query('other_expenses',where:'plot_id=?',whereArgs:[plotId]); final e=await db.query('earnings',where:'plot_id=?',whereArgs:[plotId]);
    double sum(List<Map<String,dynamic>> x,String k)=>x.fold(0.0,(v,r)=>v+(r[k] as num).toDouble());
    final spray=sprays.fold(0.0,(v,r)=>v+(r['total_cost'] as num).toDouble()), drip=drips.fold(0.0,(v,r)=>v+(r['total_cost'] as num).toDouble()), labour=sum(l,'total_cost'), other=sum(o,'amount'), earned=sum(e,'amount'); final expense=spray+drip+labour+other;
    return {'spray':spray,'drip':drip,'labour':labour,'other':other,'expense':expense,'earnings':earned,'profit':earned-expense};
  }
  Future<Map<String,double>> allPlotTotals() async {
    double spray=0,drip=0,labour=0,other=0,earned=0; for(final p in await getPlots()){final t=await plotTotals(p['id'] as int);spray+=t['spray']!;drip+=t['drip']!;labour+=t['labour']!;other+=t['other']!;earned+=t['earnings']!;} final expense=spray+drip+labour+other; return {'spray':spray,'drip':drip,'labour':labour,'other':other,'expense':expense,'earnings':earned,'profit':earned-expense};
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

      await txn.delete('labour_records', where: 'plot_id = ?', whereArgs: [id]);
      await txn.delete('other_expenses', where: 'plot_id = ?', whereArgs: [id]);
      await txn.delete('earnings', where: 'plot_id = ?', whereArgs: [id]);
      await txn.delete('app_settings', where: 'key = ?', whereArgs: ['last_page_$id']);
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
        final multiplier =
            dripDosageMultiplier(chemical.dosageUnit, chemical.unit);
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
        final multiplier =
            dripDosageMultiplier(chemical.dosageUnit, chemical.unit);
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

  Future<Map<String, dynamic>> exportPlot(int plotId) async {
    final db=await database;
    final plots=await db.query('plots',where:'id=?',whereArgs:[plotId]);
    if(plots.isEmpty) throw StateError('Plot not found.');
    final sprays=await db.query('sprays',where:'plot_id=?',whereArgs:[plotId]);
    final sprayIds=sprays.map((r)=>r['id']).toList();
    final drips=await db.query('drip_applications',where:'plot_id=?',whereArgs:[plotId]);
    final dripIds=drips.map((r)=>r['id']).toList();
    final sprayChemicals=<Map<String,dynamic>>[]; for(final id in sprayIds){ sprayChemicals.addAll(await db.query('spray_chemicals',where:'spray_id=?',whereArgs:[id])); }
    final dripChemicals=<Map<String,dynamic>>[]; for(final id in dripIds){ dripChemicals.addAll(await db.query('drip_chemicals',where:'drip_id=?',whereArgs:[id])); }
    final labour=await db.query('labour_records',where:'plot_id=?',whereArgs:[plotId]);
    final other=await db.query('other_expenses',where:'plot_id=?',whereArgs:[plotId]);
    final earnings=await db.query('earnings',where:'plot_id=?',whereArgs:[plotId]);
    return {'format':'FarmBook plot backup','version':2,'exported_at':DateTime.now().toIso8601String(),'plots':plots.map(Map<String,dynamic>.from).toList(),'sprays':sprays.map(Map<String,dynamic>.from).toList(),'spray_chemicals':sprayChemicals,'drip_applications':drips.map(Map<String,dynamic>.from).toList(),'drip_chemicals':dripChemicals,'labour_records':labour.map(Map<String,dynamic>.from).toList(),'other_expenses':other.map(Map<String,dynamic>.from).toList(),'earnings':earnings.map(Map<String,dynamic>.from).toList()};
  }

  Future<Map<String, dynamic>> exportHistory() async {
    final db = await database;

    final plots = await db.query('plots', orderBy: 'id ASC');
    final sprays = await db.query('sprays', orderBy: 'id ASC');
    final sprayChemicals = await db.query('spray_chemicals', orderBy: 'id ASC');
    final drips = await db.query('drip_applications', orderBy: 'id ASC');
    final dripChemicals = await db.query('drip_chemicals', orderBy: 'id ASC');
    final labour = await db.query('labour_records', orderBy: 'id ASC');
    final other = await db.query('other_expenses', orderBy: 'id ASC');
    final earnings = await db.query('earnings', orderBy: 'id ASC');

    return {
      'format': 'FarmBook plot backup',
      'legacy_format': 'FarmBook spray history backup',
      'version': 2,
      'exported_at': DateTime.now().toIso8601String(),
      'plots': plots.map(Map<String, dynamic>.from).toList(),
      'sprays': sprays.map(Map<String, dynamic>.from).toList(),
      'spray_chemicals':
          sprayChemicals.map(Map<String, dynamic>.from).toList(),
      'drip_applications': drips.map(Map<String, dynamic>.from).toList(),
      'drip_chemicals':
          dripChemicals.map(Map<String, dynamic>.from).toList(),
      'labour_records': labour.map(Map<String, dynamic>.from).toList(),
      'other_expenses': other.map(Map<String, dynamic>.from).toList(),
      'earnings': earnings.map(Map<String, dynamic>.from).toList(),
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
    final rawLabour = payload['labour_records'] is List ? payload['labour_records'] as List : const [];
    final rawOther = payload['other_expenses'] is List ? payload['other_expenses'] as List : const [];
    final rawEarnings = payload['earnings'] is List ? payload['earnings'] as List : const [];

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
    int labourAdded = 0;
    int otherAdded = 0;
    int earningsAdded = 0;
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

      for (final item in rawLabour) {
        if (item is! Map) { skipped++; continue; }
        final oldPlotId=_backupInt(item['plot_id']); final plotId=oldPlotId==null?null:plotIdMap[oldPlotId];
        final date=item['labour_date']?.toString()??''; final work=item['work_type']?.toString()??''; final amount=_backupDouble(item['total_cost']);
        if(plotId==null||date.isEmpty||work.isEmpty||amount==null){skipped++;continue;}
        final exists=await txn.query('labour_records',where:'plot_id=? AND labour_date=? AND work_type=? AND total_cost=?',whereArgs:[plotId,date,work,amount],limit:1);
        if(exists.isNotEmpty){skipped++;continue;}
        await txn.insert('labour_records',{'plot_id':plotId,'labour_date':date,'work_type':work,'worker_count':_backupDouble(item['worker_count'])??0,'rate':_backupDouble(item['rate'])??0,'total_cost':amount,'notes':item['notes']?.toString()??'','created_at':item['created_at']?.toString()??DateTime.now().toIso8601String()}); labourAdded++;
      }
      for (final item in rawOther) {
        if (item is! Map) { skipped++; continue; }
        final oldPlotId=_backupInt(item['plot_id']); final plotId=oldPlotId==null?null:plotIdMap[oldPlotId];
        final date=item['expense_date']?.toString()??''; final desc=item['description']?.toString()??''; final amount=_backupDouble(item['amount']);
        if(plotId==null||date.isEmpty||desc.isEmpty||amount==null){skipped++;continue;}
        final exists=await txn.query('other_expenses',where:'plot_id=? AND expense_date=? AND description=? AND amount=?',whereArgs:[plotId,date,desc,amount],limit:1);
        if(exists.isNotEmpty){skipped++;continue;}
        await txn.insert('other_expenses',{'plot_id':plotId,'expense_date':date,'category':item['category']?.toString()??'Other','description':desc,'amount':amount,'notes':item['notes']?.toString()??'','created_at':item['created_at']?.toString()??DateTime.now().toIso8601String()}); otherAdded++;
      }
      for (final item in rawEarnings) {
        if (item is! Map) { skipped++; continue; }
        final oldPlotId=_backupInt(item['plot_id']); final plotId=oldPlotId==null?null:plotIdMap[oldPlotId];
        final date=item['earning_date']?.toString()??''; final desc=item['description']?.toString()??''; final amount=_backupDouble(item['amount']);
        if(plotId==null||date.isEmpty||desc.isEmpty||amount==null){skipped++;continue;}
        final exists=await txn.query('earnings',where:'plot_id=? AND earning_date=? AND description=? AND amount=?',whereArgs:[plotId,date,desc,amount],limit:1);
        if(exists.isNotEmpty){skipped++;continue;}
        await txn.insert('earnings',{'plot_id':plotId,'earning_date':date,'description':desc,'quantity':_backupDouble(item['quantity'])??0,'unit':item['unit']?.toString()??'','price':_backupDouble(item['price'])??0,'amount':amount,'notes':item['notes']?.toString()??'','created_at':item['created_at']?.toString()??DateTime.now().toIso8601String()}); earningsAdded++;
      }
    });

    return {
      'plots_added': plotsAdded,
      'sprays_added': spraysAdded,
      'drips_added': dripsAdded,
      'labour_added': labourAdded,
      'other_added': otherAdded,
      'earnings_added': earningsAdded,
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
// DRIP COST HELPERS
// ============================================================
//
// The chemical database is the single source of truth for the
// chemical's unit. Drip dosage is therefore automatic:
//   ml or L    -> L/acre
//   gram or kg -> kg/acre
//
// Legacy chemicals with no unit keep the old L/acre default until
// their unit is filled in from the Chemical Database.
String dripDosageUnitForChemical(String chemicalUnit, {String legacyUnit = 'L/acre'}) {
  switch (chemicalUnit.trim().toLowerCase()) {
    case 'ml':
    case 'l':
      return 'L/acre';
    case 'gram':
    case 'kg':
      return 'kg/acre';
    default:
      return legacyUnit;
  }
}

double dripDosageMultiplier(String dosageUnit, String chemicalUnit) {
  final unit = chemicalUnit.trim().toLowerCase();
  if (dosageUnit == 'kg/acre') {
    return unit == 'kg' ? 1.0 : 1000.0;
  }
  return unit == 'l' ? 1.0 : 1000.0;
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
    this.unit = '',
    this.dosage = 0,
    this.dosageUnit = 'L/acre',
  });

  final int id;
  final String name;
  final double price;
  final String unit;
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
      if(last=='spray'||last=='drip') page=PlotSpraysPage(plotId:id,plotTitle:title,plotName:name,cropVariety:crop);
      else if(last=='labour') page=LabourPage(plotId:id,plotTitle:title);
      else if(last=='other') page=OtherExpensesPage(plotId:id,plotTitle:title);
      else if(last=='earnings') page=EarningsPage(plotId:id,plotTitle:title);
    }
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

String _fbMoney(double v) => '₹${v.toStringAsFixed(2)}';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    totals = await AppDatabase.instance.plotTotals(widget.plotId);
    if (!mounted) return;
    setState(() => loading = false);
  }

  Future<void> _openSection(String page, Widget child) async {
    await AppDatabase.instance.setLastPage(widget.plotId, page);
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
              _fbMoney(value),
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
                            _fbMoney(expense),
                            style: const TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0D47A1),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text('Total Earnings', style: TextStyle(color: Colors.grey)),
                          Text(
                            _fbMoney(earnings),
                            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                          ),
                          const Divider(height: 28),
                          Text(
                            profit >= 0 ? 'PROFIT' : 'LOSS',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: profit >= 0 ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          ),
                          Text(
                            _fbMoney(profit.abs()),
                            style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.bold,
                              color: profit >= 0 ? Colors.green.shade700 : Colors.red.shade700,
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
                  subtitle: Text(_formatDate(date)),
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
          Card(color: const Color(0xFFE3F2FD), child: ListTile(title: const Text('Total Labour Cost'), trailing: Text(_fbMoney(total), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Color(0xFF0D47A1))))),
          ...rows.map((row) => Card(child: ListTile(
            title: Text(row['work_type'].toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${_formatDate(DateTime.parse(row['labour_date'].toString()))} • ${(row['worker_count'] as num)} workers × ₹${(row['rate'] as num).toStringAsFixed(2)}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [Text(_fbMoney((row['total_cost'] as num).toDouble())), PopupMenuButton<String>(onSelected: (v) { if (v == 'edit') _form(row); else _delete(row['id'] as int); }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))])]),
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
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.calendar_today), title: const Text('Date'), subtitle: Text(_formatDate(date)), onTap: () async { final picked = await showDatePicker(context: dc, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (picked != null) set(() => date = picked); }),
        TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Cancel')), FilledButton(onPressed: () async { final value = double.tryParse(amount.text.trim()); if (desc.text.trim().isEmpty || value == null || value < 0) return; if (row == null) { await AppDatabase.instance.addOtherExpense(plotId: widget.plotId, date: date, category: category, description: desc.text, amount: value, notes: notes.text); } else { await AppDatabase.instance.updateOtherExpense(id: row['id'] as int, date: date, category: category, description: desc.text, amount: value, notes: notes.text); } if (dc.mounted) Navigator.pop(dc); await _load(); }, child: const Text('Save'))],
    ))); desc.dispose(); amount.dispose(); notes.dispose();
  }
  Future<void> _delete(int id) async { await AppDatabase.instance.deleteOtherExpense(id); await _load(); }
  @override Widget build(BuildContext context) { final total=rows.fold<double>(0,(sum,row)=>sum+(row['amount']as num).toDouble()); return Scaffold(appBar:AppBar(title:Text('${widget.plotTitle} • Expenses')),floatingActionButton:FloatingActionButton.extended(onPressed:()=>_form(),backgroundColor:const Color(0xFF0D47A1),foregroundColor:Colors.white,icon:const Icon(Icons.add),label:const Text('Add expense')),body:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.fromLTRB(12,12,12,100),children:[Card(color:const Color(0xFFE3F2FD),child:ListTile(title:const Text('Total Other Expenses'),trailing:Text(_fbMoney(total),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold,color:Color(0xFF0D47A1))))),...rows.map((row)=>Card(child:ListTile(title:Text(row['description'].toString()),subtitle:Text('${row['category']} • ${_formatDate(DateTime.parse(row['expense_date'].toString()))}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(_fbMoney((row['amount']as num).toDouble())),PopupMenuButton<String>(onSelected:(v){if(v=='edit')_form(row);else _delete(row['id']as int);},itemBuilder:(_)=>const[PopupMenuItem(value:'edit',child:Text('Edit')),PopupMenuItem(value:'delete',child:Text('Delete'))])])))]); }
}

class EarningsPage extends StatefulWidget {
  const EarningsPage({super.key, required this.plotId, required this.plotTitle});
  final int plotId; final String plotTitle;
  @override State<EarningsPage> createState() => _EarningsPageState();
}
class _EarningsPageState extends State<EarningsPage> {
  List<Map<String,dynamic>> rows=[]; bool loading=true;
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{rows=await AppDatabase.instance.getEarnings(widget.plotId);if(mounted)setState(()=>loading=false);}
  Future<void> _form([Map<String,dynamic>? row])async{
    final desc=TextEditingController(text:row?['description']?.toString()??'');
    final qty=TextEditingController(text:row==null?'':(row['quantity']as num).toString());
    final unit=TextEditingController(text:row?['unit']?.toString()??'kg');
    final price=TextEditingController(text:row==null?'':(row['price']as num).toString());
    final amount=TextEditingController(text:row==null?'':(row['amount']as num).toString());
    final notes=TextEditingController(text:row?['notes']?.toString()??'');
    DateTime date=row==null?DateTime.now():DateTime.parse(row['earning_date'].toString());
    await showDialog<void>(context:context,builder:(dc)=>StatefulBuilder(builder:(dc,set)=>AlertDialog(title:Text(row==null?'Add earning':'Edit earning'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:desc,decoration:const InputDecoration(labelText:'Description')),TextField(controller:qty,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Quantity')),TextField(controller:unit,decoration:const InputDecoration(labelText:'Unit (kg, box, etc.)')),TextField(controller:price,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Price / unit (₹)')),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Total earning (₹)')),ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.calendar_today),title:const Text('Date'),subtitle:Text(_formatDate(date)),onTap:()async{final picked=await showDatePicker(context:dc,initialDate:date,firstDate:DateTime(2000),lastDate:DateTime(2100));if(picked!=null)set(()=>date=picked);}),TextField(controller:notes,maxLines:2,decoration:const InputDecoration(labelText:'Notes'))])),actions:[TextButton(onPressed:()=>Navigator.pop(dc),child:const Text('Cancel')),FilledButton(onPressed:()async{final value=double.tryParse(amount.text.trim());if(desc.text.trim().isEmpty||value==null||value<0)return;final q=double.tryParse(qty.text.trim())??0;final p=double.tryParse(price.text.trim())??0;if(row==null)await AppDatabase.instance.addEarning(plotId:widget.plotId,date:date,description:desc.text,quantity:q,unit:unit.text,price:p,amount:value,notes:notes.text);else await AppDatabase.instance.updateEarning(id:row['id']as int,date:date,description:desc.text,quantity:q,unit:unit.text,price:p,amount:value,notes:notes.text);if(dc.mounted)Navigator.pop(dc);await _load();},child:const Text('Save'))]));desc.dispose();qty.dispose();unit.dispose();price.dispose();amount.dispose();notes.dispose();}
  Future<void> _delete(int id)async{await AppDatabase.instance.deleteEarning(id);await _load();}
  @override Widget build(BuildContext context){final total=rows.fold<double>(0,(sum,row)=>sum+(row['amount']as num).toDouble());return Scaffold(appBar:AppBar(title:Text('${widget.plotTitle} • Earnings')),floatingActionButton:FloatingActionButton.extended(onPressed:()=>_form(),backgroundColor:const Color(0xFF0D47A1),foregroundColor:Colors.white,icon:const Icon(Icons.add),label:const Text('Add earning')),body:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.fromLTRB(12,12,12,100),children:[Card(color:const Color(0xFFE3F2FD),child:ListTile(title:const Text('Total Earnings'),trailing:Text(_fbMoney(total),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold,color:Color(0xFF0D47A1))))),...rows.map((row)=>Card(child:ListTile(title:Text(row['description'].toString(),style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${_formatDate(DateTime.parse(row['earning_date'].toString()))} • ${(row['quantity']as num)} ${row['unit']} × ₹${(row['price']as num).toStringAsFixed(2)}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(_fbMoney((row['amount']as num).toDouble())),PopupMenuButton<String>(onSelected:(v){if(v=='edit')_form(row);else _delete(row['id']as int);},itemBuilder:(_)=>const[PopupMenuItem(value:'edit',child:Text('Edit')),PopupMenuItem(value:'delete',child:Text('Delete'))])])))]);}
}

class FarmOverviewPage extends StatefulWidget { const FarmOverviewPage({super.key}); @override State<FarmOverviewPage> createState()=>_FarmOverviewPageState(); }
class _FarmOverviewPageState extends State<FarmOverviewPage>{Map<String,double> totals={};bool loading=true;@override void initState(){super.initState();_load();}Future<void>_load()async{totals=await AppDatabase.instance.allPlotTotals();if(mounted)setState(()=>loading=false);}@override Widget build(BuildContext context){final profit=totals['profit']??0;return Scaffold(appBar:AppBar(title:const Text('Farm Overview')),body:loading?const Center(child:CircularProgressIndicator()):RefreshIndicator(onRefresh:_load,child:ListView(padding:const EdgeInsets.all(14),children:[Card(color:const Color(0xFFE3F2FD),child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('ALL PLOTS',style:TextStyle(fontWeight:FontWeight.bold,color:Color(0xFF0D47A1))),const SizedBox(height:12),Text('Total Expenses  ${_fbMoney(totals['expense']??0)}'),Text('Total Earnings  ${_fbMoney(totals['earnings']??0)}'),const Divider(),Text(profit>=0?'TOTAL PROFIT':'TOTAL LOSS',style:TextStyle(fontWeight:FontWeight.bold)),Text(_fbMoney(profit.abs()),style:TextStyle(fontSize:28,fontWeight:FontWeight.bold,color:profit>=0?Colors.green.shade700:Colors.red.shade700))])),_farmTotal('Spray',totals['spray']??0),_farmTotal('Drip / Irrigation',totals['drip']??0),_farmTotal('Labour',totals['labour']??0),_farmTotal('Other Expenses',totals['other']??0)])));}Widget _farmTotal(String title,double value)=>Card(child:ListTile(title:Text(title),trailing:Text(_fbMoney(value),style:const TextStyle(fontWeight:FontWeight.bold))));}

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
                await AppDatabase.instance.setLastPage(widget.plotId, 'spray');
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
                await AppDatabase.instance.setLastPage(widget.plotId, 'drip');
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
                            headingRowColor: WidgetStateProperty.all(
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
            _formatNumber((drip['acres'] as num).toDouble());
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
                                  multiplier == 1.0 ? '' : '× ${_formatNumber(multiplier)} ';
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Cost: ${_formatNumber(_acres)} acres × '
                                    '${_formatNumber(chemical.dosage)} ${chemical.dosageUnit} '
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
