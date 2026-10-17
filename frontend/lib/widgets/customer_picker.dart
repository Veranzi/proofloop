import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/api.dart';
import '../core/models.dart';

/// "Customer (optional)" dropdown, filled from GET /v1/customers (57).
class CustomerPicker extends StatefulWidget {
  const CustomerPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// The selected customer ID, or null for none.
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  State<CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<CustomerPicker> {
  late Future<List<Customer>> _future = PrufloApi().customers();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Customer (optional)',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        FutureBuilder<List<Customer>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Couldn't load customers.",
                      style: TextStyle(fontSize: 13, color: AppColors.danger),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() {
                          _future = PrufloApi().customers();
                        }),
                    child: const Text('Retry'),
                  ),
                ],
              );
            }
            final customers = snapshot.data;
            if (customers == null) {
              return const LinearProgressIndicator(minHeight: 2);
            }
            // Keep a selection that isn't in the list (e.g. renamed) valid.
            final value = customers.any((c) => c.id == widget.value)
                ? widget.value
                : null;
            return DropdownButtonFormField<String?>(
              initialValue: value,
              isExpanded: true,
              hint: Text(
                customers.isEmpty
                    ? 'No customers yet (an admin can add them)'
                    : 'No customer',
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('No customer'),
                ),
                for (final c in customers)
                  DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: widget.enabled && customers.isNotEmpty
                  ? widget.onChanged
                  : null,
            );
          },
        ),
      ],
    );
  }
}
