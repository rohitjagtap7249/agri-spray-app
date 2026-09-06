import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'helpers.dart';

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
  // FARM DASHBOARD (read-only helpers; no schema changes)
  // ------------------------------------------------------------

  /// Returns the most recent spray for a plot (or null if none), using the
  /// same computed rows as [getSpraysForPlot].
  Future<Map<String, dynamic>?> getLastSprayForPlot(int plotId) async {
    final sprays = await getSpraysForPlot(plotId);
    return sprays.isEmpty ? null : sprays.first;
  }

  /// Merges recent sprays, drip applications, labour, other expenses and
  /// earnings into a single "recent activity" feed for the Home dashboard.
  /// Purely additive/read-only: does not touch any existing table or data.
  Future<List<Map<String, dynamic>>> getRecentActivity({int limit = 6}) async {
    final db = await database;
    final plots = await getPlots();
    final plotTitle = <int, String>{
      for (final p in plots) p['id'] as int: p['title'].toString(),
    };

    final items = <Map<String, dynamic>>[];

    final sprays = await db.query('sprays', orderBy: 'created_at DESC', limit: limit);
    for (final r in sprays) {
      items.add({
        'type': 'spray',
        'title': 'Spray record added',
        'subtitle': plotTitle[r['plot_id'] as int] ?? '',
        'created_at': r['created_at'].toString(),
      });
    }

    final drips = await db.query('drip_applications', orderBy: 'created_at DESC', limit: limit);
    for (final r in drips) {
      items.add({
        'type': 'drip',
        'title': 'Drip application added',
        'subtitle': plotTitle[r['plot_id'] as int] ?? '',
        'created_at': r['created_at'].toString(),
      });
    }

    final labour = await db.query('labour_records', orderBy: 'created_at DESC', limit: limit);
    for (final r in labour) {
      items.add({
        'type': 'labour',
        'title': 'Labour recorded',
        'subtitle': plotTitle[r['plot_id'] as int] ?? '',
        'created_at': r['created_at'].toString(),
      });
    }

    final other = await db.query('other_expenses', orderBy: 'created_at DESC', limit: limit);
    for (final r in other) {
      items.add({
        'type': 'expense',
        'title': 'Expense added',
        'subtitle': plotTitle[r['plot_id'] as int] ?? '',
        'created_at': r['created_at'].toString(),
      });
    }

    final earnings = await db.query('earnings', orderBy: 'created_at DESC', limit: limit);
    for (final r in earnings) {
      items.add({
        'type': 'earning',
        'title': 'Earning added',
        'subtitle': plotTitle[r['plot_id'] as int] ?? '',
        'created_at': r['created_at'].toString(),
      });
    }

    items.sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    return items.take(limit).toList();
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

  /// Returns raw pesticide-usage rows calculated from existing Spray records.
  /// No duplicate usage records are stored. Quantity is calculated as
  /// spray water × chemical dosage, using the chemical's configured unit.
  Future<List<Map<String, dynamic>>> getPesticideUsageRows() async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        sc.id,
        sc.spray_id,
        sc.chemical_id,
        sc.chemical_name,
        sc.dosage,
        COALESCE(c.unit, '') AS unit,
        s.spray_date,
        s.water,
        p.crop_variety,
        p.title AS plot_title
      FROM spray_chemicals sc
      INNER JOIN sprays s ON s.id = sc.spray_id
      INNER JOIN plots p ON p.id = s.plot_id
      LEFT JOIN chemicals c ON c.id = sc.chemical_id
      ORDER BY sc.chemical_name COLLATE NOCASE ASC, s.spray_date DESC, sc.id DESC
    ''');
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
