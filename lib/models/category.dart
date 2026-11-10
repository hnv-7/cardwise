import 'package:flutter/material.dart';

/// Spending categories. Keep [name] stable: it is persisted.
enum SpendCategory {
  groceries('Groceries', Icons.shopping_basket_outlined, Color(0xFF43A047)),
  dining('Dining', Icons.restaurant_outlined, Color(0xFFEF6C00)),
  travel('Travel', Icons.flight_outlined, Color(0xFF1E88E5)),
  utilities('Utilities', Icons.bolt_outlined, Color(0xFFFDD835)),
  fuel('Fuel', Icons.local_gas_station_outlined, Color(0xFF6D4C41)),
  shopping('Shopping', Icons.shopping_bag_outlined, Color(0xFF8E24AA)),
  entertainment('Entertainment', Icons.movie_outlined, Color(0xFFE53935)),
  health('Health', Icons.local_hospital_outlined, Color(0xFF00ACC1)),
  other('Other', Icons.category_outlined, Color(0xFF78909C));

  const SpendCategory(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  static SpendCategory fromName(String? name) => SpendCategory.values
      .firstWhere((c) => c.name == name, orElse: () => SpendCategory.other);
}
