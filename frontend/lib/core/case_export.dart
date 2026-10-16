import 'dart:convert';

import 'models.dart';

/// Machine-readable export of a case's findings, as returned by
/// GET /v1/cases/{caseId}/export (endpoint 50).
///
/// Until the API exists this builds a sample with the same shape, using the
/// ordered 100 / delivered 80 shortfall from the architecture report.
/// The shape is documented in Docs/Integrations_API_Contract.md.
class CaseExport {
  CaseExport._();

  static Map<String, dynamic> sample(CaseItem c) => {
    'schema_version': '1.0',
    'case': {'id': c.id, 'title': c.title, 'status': 'reviewed'},
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'findings': [
      {
        'id': 'fnd_7c1e',
        'rule_id': 'quantity_shortfall',
        'rule_version': 3,
        'type': 'quantity_shortfall',
        'severity': 'high',
        'expected': {'value': '100', 'unit': 'units'},
        'observed': {'value': '80', 'unit': 'units'},
        'difference': {'value': '20', 'unit': 'units'},
        'review': {
          'status': 'confirmed',
          'by': 'Sarah Johnson',
          'at': DateTime.now().toUtc().toIso8601String(),
          'note': 'Supplier confirmed 20 units back-ordered.',
        },
        'explanation':
            'The purchase order lists 100 units; the delivery note '
            'records 80 units received.',
        'explanation_source': 'machine_generated',
        'evidence': [
          {
            'claim_id': 'clm_a01',
            'field': 'ordered_quantity',
            'value': '100',
            'evidence_id': 'evd_po_001',
            'file_name': 'purchase_order.pdf',
            'page': 1,
            'quote': 'Qty ordered: 100',
            'grounding': 'grounded',
            'source_url':
                '/v1/cases/${c.id}/evidence/evd_po_001/view-url?page=1',
          },
          {
            'claim_id': 'clm_a02',
            'field': 'delivered_quantity',
            'value': '80',
            'evidence_id': 'evd_dn_001',
            'file_name': 'delivery_note.pdf',
            'page': 1,
            'quote': 'Received: 80',
            'grounding': 'grounded',
            'source_url':
                '/v1/cases/${c.id}/evidence/evd_dn_001/view-url?page=1',
          },
        ],
      },
    ],
  };

  static String json(CaseItem c) =>
      const JsonEncoder.withIndent('  ').convert(sample(c));

  /// One row per finding; evidence references are joined with "; ".
  static String csv(CaseItem c) {
    const header = [
      'case_id',
      'finding_id',
      'rule_id',
      'rule_version',
      'severity',
      'expected',
      'observed',
      'difference',
      'unit',
      'review_status',
      'reviewed_by',
      'reviewed_at',
      'evidence',
    ];
    final data = sample(c);
    final rows = <List<String>>[header];
    for (final f in data['findings'] as List) {
      final review = f['review'] as Map;
      final evidence = (f['evidence'] as List)
          .map((e) => '${e['file_name']} p${e['page']}')
          .join('; ');
      rows.add([
        c.id,
        f['id'],
        f['rule_id'],
        '${f['rule_version']}',
        f['severity'],
        f['expected']['value'],
        f['observed']['value'],
        f['difference']['value'],
        f['difference']['unit'],
        review['status'],
        review['by'],
        review['at'],
        evidence,
      ]);
    }
    return rows.map((r) => r.map(_cell).join(',')).join('\n');
  }

  static String _cell(String v) =>
      RegExp(r'[",\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
}
