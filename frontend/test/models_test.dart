import 'package:flutter_test/flutter_test.dart';

import 'package:pruflo/core/auth_service.dart';
import 'package:pruflo/core/integration_models.dart';
import 'package:pruflo/core/models.dart';

/// The JSON here is copied from Docs/API_Contract.md and
/// Docs/Integrations_API_Contract.md, so a contract change that breaks the
/// app fails these tests.
void main() {
  test('Case and Finding parse the contract shapes', () {
    final c = CaseItem.fromJson({
      'id': 'case_1',
      'reference': 'PL-001',
      'title': 'Delivery check',
      'category': '',
      'description': '',
      'status': 'in_review',
      'priority': 'high',
      'customer_id': null,
      'assigned_to': {'uid': 'u_1', 'name': 'Sarah'},
      'created_at': '2026-10-16T09:30:00Z',
      'updated_at': '2026-10-16T09:30:00Z',
      'version': 3,
    });
    expect(c.status, CaseStatus.inReview);
    expect(c.reference, 'PL-001');
    expect(c.assignedTo!.name, 'Sarah');

    final f = Finding.fromJson({
      'id': 'fnd_7c1e',
      'rule_id': 'rule_qty',
      'rule_version': 3,
      'type': 'quantity_shortfall',
      'severity': 'high',
      'expected': {'value': '100', 'unit': 'units'},
      'observed': {'value': '80', 'unit': 'units'},
      'difference': {'value': '20', 'unit': 'units'},
      'explanation': '...',
      'explanation_source': 'machine_generated',
      'review': {
        'status': 'approve',
        'by': {'uid': 'u_1', 'name': 'Sarah'},
        'at': '2026-10-16T09:10:00Z',
        'note': 'Supplier confirmed.',
        'correction': null,
      },
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
        },
      ],
      'created_at': '2026-10-16T09:00:00Z',
    });
    expect(f.difference.toString(), '20 units');
    expect(f.review.status, ReviewDecision.approve);
    expect(f.evidence.single.id, 'clm_a01'); // export uses claim_id
    expect(f.title, 'Quantity shortfall');
  });

  test('wire values match the backend enums', () {
    expect(CaseStatus.values.map((s) => s.wire),
        ['awaiting_evidence', 'in_review', 'completed']);
    expect(ReviewDecision.values.map((d) => d.wire),
        ['approve', 'reject', 'pending']);
    expect(UserRole.viewer.canExport, isFalse);
    expect(UserRole.reviewer.canDecide, isTrue);
    expect(UserRole.investigator.canDecide, isFalse);
  });

  test('integration models parse the integrations contract', () {
    final key = ApiKey.fromJson({
      'id': 'key_1',
      'name': 'ERP sync',
      'prefix': 'pf_live_7Hq2',
      'scopes': ['cases:write', 'evidence:write', 'unknown:scope'],
      'created_at': '2026-10-04T08:00:00Z',
      'created_by': {'uid': 'u_123', 'name': 'An Admin'},
      'last_used_at': null,
      'revoked': false,
    });
    expect(key.scopes, {ApiScope.casesWrite, ApiScope.evidenceWrite});
    expect(key.createdBy, 'An Admin');

    final hook = WebhookEndpoint.fromJson({
      'id': 'wh_1',
      'url': 'https://erp.example.com/hooks/pruflo',
      'description': '',
      'events': ['case.in_review', 'finding.decided'],
      'active': true,
      'created_at': '2026-10-07T10:00:00Z',
      'recent_deliveries': [
        {'id': 'dlv_1', 'event': 'ping', 'status_code': 0, 'attempt': 1,
         'at': '2026-10-16T08:30:00Z'},
      ],
    });
    expect(hook.events,
        {WebhookEvent.caseInReview, WebhookEvent.findingDecided});
    expect(hook.deliveries.single.event, 'ping');
    expect(hook.deliveries.single.succeeded, isFalse);

    expect(
        Connector.fromJson({'kind': 'sap', 'status': 'coming_soon'})!.status,
        ConnectorStatus.comingSoon);
    expect(Connector.fromJson({'kind': 'fax', 'status': 'connected'}), isNull);

    final rule = ReconciliationRule.fromJson({
      'id': 'rule_qty',
      'template': 'quantity_shortfall',
      'name': 'Quantity shortfall',
      'description': '',
      'version': 3,
      'enabled': true,
      'params': [
        {'key': 'tolerance_units', 'label': 'Allowed difference', 'value': '0',
         'suffix': 'units'},
      ],
    });
    expect(rule.params.single.value, '0');

    final providers = ProviderSettings.fromJson({
      'ocr': 'google_document_ai',
      'ai': 'vertex_gemini',
      'model': 'gemini-2.5-flash',
      'region': 'asia-southeast1',
    });
    expect(providers.toJson()['region'], 'asia-southeast1');
    expect(regionLabel('asia-southeast1'), 'Singapore (asia-southeast1)');
  });

  test('development token matches what the API expects', () {
    expect(AuthService.devToken(' Someone@Example.com '),
        'dev:local-someone-example-com:someone@example.com');
  });
}
