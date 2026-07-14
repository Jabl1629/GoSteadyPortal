// Fleet rotation UX (d2c-claim-binding.md §5.4) — the /fleet route is
// internal-auth-gated, so it can't be driven headlessly. The presentational
// logic (reserved pill, "open (unbound)" warning, the ⋯ rotate menu) is
// analyze-clean and driven entirely by `FleetDevice.claimBoundPhoneMask` +
// `owningClientId` + `status`. This locks the one piece with untested value:
// that the mask actually survives the API-row → model parse the row states
// read from. (Live end-to-end proof of the field lives in the dev E2E:
// scratchpad/e2e_rotation.py T-bind + the device-api TestFleetRowMask unit
// test; the consumer /setup "reserved" landing is screenshot-verified live.)
import 'package:flutter_test/flutter_test.dart';
import 'package:gosteady_portal/api/api_models.dart';

void main() {
  test('FleetDevice.fromJson surfaces claimBoundPhoneMask (reserved row)', () {
    final d = FleetDevice.fromJson({
      'serialNumber': 'GS0009000001',
      'status': 'ready_to_provision',
      'claimBoundPhoneMask': '•••-1234',
    });
    expect(d.claimBoundPhoneMask, '•••-1234');
    // Reserved-pill predicate the row uses: bound + unowned.
    expect(d.owningClientId, isNull);
  });

  test('FleetDevice.fromJson: unbound row → null mask (drives "open" warning)',
      () {
    final d = FleetDevice.fromJson({
      'serialNumber': 'GS0009000002',
      'status': 'ready_to_provision',
    });
    expect(d.claimBoundPhoneMask, isNull);
  });
}
