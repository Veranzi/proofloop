import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:pruflo/core/case_export.dart';
import 'package:pruflo/core/integration_models.dart';
import 'package:pruflo/core/integrations_repository.dart';
import 'package:pruflo/core/mock_repository.dart';

void main() {
  final repo = IntegrationsRepository.instance;
  final aCase = MockRepository.instance.cases().first;

  test('new API key secret is returned once and only its prefix is kept', () {
    final (key, secret) = repo.createApiKey(
      name: 'Test',
      scopes: {ApiScope.casesRead},
      createdBy: 'Tester',
    );
    expect(secret, startsWith('pf_live_'));
    expect(secret.startsWith(key.prefix), isTrue);
    expect(key.prefix.length, lessThan(secret.length));
    repo.revokeApiKey(key.id);
    expect(repo.apiKeys().firstWhere((k) => k.id == key.id).revoked, isTrue);
  });

  test('changing rule parameters creates a new version; toggling does not', () {
    final rule = repo.rules().first;
    final toggled = rule.copyWith(enabled: !rule.enabled);
    expect(toggled.version, rule.version);
    final edited = rule.copyWith(params: [rule.params.first.withValue('5')]);
    expect(edited.version, rule.version + 1);
  });

  test('JSON export carries rule version and source references', () {
    final data = jsonDecode(CaseExport.json(aCase)) as Map<String, dynamic>;
    final finding = (data['findings'] as List).first as Map<String, dynamic>;
    expect(data['schema_version'], '1.0');
    expect(finding['difference'], {'value': '20', 'unit': 'units'});
    expect(finding['rule_version'], isA<int>());
    for (final e in finding['evidence'] as List) {
      expect(e['page'], isA<int>());
      expect(e['quote'], isNotEmpty);
    }
  });

  test('CSV export has one header row plus one row per finding', () {
    final lines = CaseExport.csv(aCase).split('\n');
    expect(lines.first, startsWith('case_id,finding_id,rule_id'));
    expect(lines, hasLength(2));
    expect(lines.last, startsWith('${aCase.id},fnd_7c1e,quantity_shortfall'));
  });
}
