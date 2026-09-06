// Shared formatting and dosage helpers used by FarmBook screens.

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


String _fbMoney(double v) => '₹${v.toStringAsFixed(2)}';

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
