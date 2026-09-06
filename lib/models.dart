// Small data models used by the database and forms.

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

